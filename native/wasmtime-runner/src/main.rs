//! The control socket is opened by the embedder. The guest receives typed
//! component imports and one private preopen, never the control descriptor.
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::time::Duration;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store, StoreContextMut, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::p2::bindings::Command as CommandP2;
use wasmtime_wasi::p3::bindings::Command as CommandP3;
use wasmtime_wasi::{FsPerms, WasiCtx, WasiCtxView, WasiView};

mod native_skills;

const FRAME_LIMIT: usize = 16 * 1024 * 1024;

struct Host {
    wasi: WasiCtx,
    table: ResourceTable,
    limits: StoreLimits,
    broker: UnixStream,
    calls: usize,
}

impl WasiView for Host {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}

type Reply = (Result<String, String>,);

impl Host {
    fn request(&mut self, service: &str, operation: &str, args: Value) -> Reply {
        self.calls += 1;
        if self.calls > 8192 {
            return (Err("Invocation service call limit exceeded".into()),);
        }
        let data = json!({"service":service,"operation":operation,"args":args}).to_string();
        if data.len() > FRAME_LIMIT {
            return (Err("Service request exceeds its byte limit".into()),);
        }
        let exchange = || -> anyhow::Result<Reply> {
            // Core bounds model preparation and inference with the step deadline.
            // Other run services retain their short response timeout.
            let timeout =
                (!matches!(service, "model" | "skill")).then_some(Duration::from_secs(100));
            self.broker.set_read_timeout(timeout)?;
            self.broker.write_all(&(data.len() as u32).to_be_bytes())?;
            self.broker.write_all(data.as_bytes())?;
            let mut head = [0; 4];
            self.broker.read_exact(&mut head)?;
            let size = u32::from_be_bytes(head) as usize;
            anyhow::ensure!(size <= FRAME_LIMIT, "Invalid service response size");
            let mut buffer = vec![0; size];
            self.broker.read_exact(&mut buffer)?;
            let reply: Value = serde_json::from_slice(&buffer)?;
            if let Some(value) = reply["ok"].as_str() {
                return Ok((Ok(value.into()),));
            }
            Ok((Err(reply["error"]
                .as_str()
                .unwrap_or("Invalid service response")
                .into()),))
        };
        let mut exchange = exchange;
        exchange().unwrap_or_else(|_| (Err("Run service connection failed".into()),))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn host(broker: UnixStream) -> Host {
        Host {
            wasi: WasiCtx::builder().build(),
            table: ResourceTable::new(),
            limits: StoreLimitsBuilder::new().build(),
            broker,
            calls: 0,
        }
    }

    fn read_request(broker: &mut UnixStream) -> Value {
        let mut size = [0; 4];
        broker.read_exact(&mut size).unwrap();
        let mut body = vec![0; u32::from_be_bytes(size) as usize];
        broker.read_exact(&mut body).unwrap();
        serde_json::from_slice(&body).unwrap()
    }

    #[test]
    fn forwards_scoped_artifact_arguments_and_returns_broker_result() {
        let (client, mut server) = UnixStream::pair().unwrap();
        server
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let broker = thread::spawn(move || {
            let request = read_request(&mut server);
            assert_eq!(
                request,
                json!({
                    "service": "artifacts", "operation": "read", "args": ["proof.json", null]
                })
            );
            let response = br#"{"ok":"receipt"}"#;
            server
                .write_all(&(response.len() as u32).to_be_bytes())
                .unwrap();
            server.write_all(response).unwrap();
        });

        assert_eq!(
            host(client).request("artifacts", "read", json!(["proof.json", null])),
            (Ok("receipt".into()),)
        );
        broker.join().unwrap();
    }

    #[test]
    fn rejects_an_oversized_broker_reply_before_reading_a_body() {
        let (client, mut server) = UnixStream::pair().unwrap();
        server
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let broker = thread::spawn(move || {
            read_request(&mut server);
            server
                .write_all(&((FRAME_LIMIT + 1) as u32).to_be_bytes())
                .unwrap();
            server
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut end = [0];
            assert_eq!(server.read(&mut end).unwrap(), 0);
        });

        assert_eq!(
            host(client).request("artifacts", "read", json!(["proof.json", null])),
            (Err("Run service connection failed".into()),)
        );
        broker.join().unwrap();
    }
}

fn link_services(linker: &mut Linker<Host>) -> wasmtime::Result<()> {
    let mut artifacts = linker.instance("mirror-neuron:run/artifacts@1.0.0")?;
    artifacts.func_wrap(
        "import-block",
        |mut s: StoreContextMut<Host>, (bundle,): (String,)| {
            Ok(s.data_mut()
                .request("artifacts", "import-block", json!([bundle])))
        },
    )?;
    artifacts.func_wrap(
        "static-report",
        |mut s: StoreContextMut<Host>, (path, hash, title): (String, String, String)| {
            Ok(s.data_mut()
                .request("artifacts", "static-report", json!([path, hash, title])))
        },
    )?;
    artifacts.func_wrap(
        "publish",
        |mut s: StoreContextMut<Host>, (refs,): (String,)| {
            Ok(s.data_mut().request("artifacts", "publish", json!([refs])))
        },
    )?;
    artifacts.func_wrap(
        "read",
        |mut s: StoreContextMut<Host>, (path, hash): (String, Option<String>)| {
            Ok(s.data_mut()
                .request("artifacts", "read", json!([path, hash])))
        },
    )?;
    artifacts.func_wrap(
        "commit",
        |mut s: StoreContextMut<Host>, (path, kind, content): (String, String, String)| {
            Ok(s.data_mut()
                .request("artifacts", "commit", json!([path, kind, content])))
        },
    )?;
    artifacts.func_wrap(
        "verify",
        |mut s: StoreContextMut<Host>, (path, hash, size): (String, String, u64)| {
            Ok(s.data_mut()
                .request("artifacts", "verify", json!([path, hash, size])))
        },
    )?;
    artifacts.func_wrap(
        "commit-json",
        |mut s: StoreContextMut<Host>, (path, kind, content): (String, String, String)| {
            Ok(s.data_mut()
                .request("artifacts", "commit-json", json!([path, kind, content])))
        },
    )?;
    linker
        .instance("mirror-neuron:run/model@1.0.0")?
        .func_wrap(
            "generate-json",
            |mut s: StoreContextMut<Host>, (system, input, schema): (String, String, String)| {
                Ok(s.data_mut()
                    .request("model", "generate-json", json!([system, input, schema])))
            },
        )?;
    for (name, ops) in [
        ("approvals", &["request", "status"][..]),
        ("mailbox", &["list", "send", "acknowledge"][..]),
    ] {
        let mut interface = linker.instance(&format!("mirror-neuron:run/{name}@1.0.0"))?;
        for &op in ops {
            interface.func_wrap(
                op,
                move |mut s: StoreContextMut<Host>, (value,): (String,)| {
                    Ok(s.data_mut().request(name, op, json!([value])))
                },
            )?;
        }
        if name == "mailbox" {
            interface.func_wrap(
                "attachment",
                |mut s: StoreContextMut<Host>, (message, field): (String, String)| {
                    Ok(s.data_mut()
                        .request("mailbox", "attachment", json!([message, field])))
                },
            )?;
        }
    }
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> wasmtime::Result<ExitCode> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 3 {
        wasmtime::bail!("Expected component, private job directory, and run-service socket");
    }
    let bytes = std::fs::read(&args[0])?;
    if !bytes.starts_with(b"\0asm\x0d\0\x01\0") {
        wasmtime::bail!("Expected a raw WebAssembly component");
    }
    let mut config = Config::new();
    config.wasm_component_model_async(true);
    let engine = Engine::new(&config)?;
    let component = Component::from_binary(&engine, &bytes)?;
    let mut linker = Linker::new(&engine);
    // A Preview 3 worker can import a Python skill built against Preview 2.
    // Both use this invocation's WasiCtx, file preopen and network policy.
    wasmtime_wasi::p2::add_to_linker_async(&mut linker)?;
    wasmtime_wasi::p3::add_to_linker(&mut linker)?;
    link_services(&mut linker)?;
    native_skills::link(&engine, &component, &mut linker)?;
    let mut builder = WasiCtx::builder();
    builder
        .inherit_stdout()
        .inherit_stderr()
        .allow_tcp(false)
        .allow_udp(false)
        .allow_ip_name_lookup(false);
    builder.preopened_dir(&args[1], "/job", FsPerms::ReadWrite)?;
    let broker = UnixStream::connect(&args[2])?;
    broker.set_write_timeout(Some(Duration::from_secs(15)))?;
    let limits = StoreLimitsBuilder::new()
        .memory_size(256 * 1024 * 1024)
        .memories(32)
        .instances(128)
        .tables(64)
        .build();
    let mut store = Store::new(
        &engine,
        Host {
            wasi: builder.build(),
            table: ResourceTable::default(),
            limits,
            broker,
            calls: 0,
        },
    );
    store.limiter(|state| &mut state.limits);
    let command_type = component.component_type();
    let preview3 = command_type
        .exports(&engine)
        .any(|(name, _)| name.starts_with("wasi:cli/run@0.3."));
    let status = if preview3 {
        let command = CommandP3::instantiate_async(&mut store, &component, &linker).await?;
        store
            .run_concurrent(async move |store| command.wasi_cli_run().call_run(store).await)
            .await??
    } else {
        let command = CommandP2::instantiate_async(&mut store, &component, &linker).await?;
        command.wasi_cli_run().call_run(&mut store).await?
    };
    // The guest already wrote its diagnostic to stderr. Let Core report it.
    Ok(if status.is_ok() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}
