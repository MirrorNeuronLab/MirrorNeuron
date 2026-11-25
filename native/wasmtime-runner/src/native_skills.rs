//! Link only bounded JSON operations of imported native skill interfaces.
//! A linked import grants no authority on its own. Core checks the exact
//! skill/operation grant and the pinned WIT dependency for every invocation.
use super::{Host, Reply};
use serde_json::json;
use wasmtime::component::{Component, Linker, types::ComponentItem};
use wasmtime::{Engine, StoreContextMut};

fn identifier(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .split('-')
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_lowercase()))
}

pub fn link(
    engine: &Engine,
    component: &Component,
    linker: &mut Linker<Host>,
) -> wasmtime::Result<()> {
    for (import, item) in component.component_type().imports(engine) {
        let Some(name) = import.strip_prefix("mirror-neuron:native/") else {
            continue;
        };
        let skill = name
            .strip_suffix("@1.0.0")
            .filter(|s| identifier(s))
            .ok_or_else(|| wasmtime::format_err!("Unsupported native skill interface"))?;
        let ComponentItem::ComponentInstance(api) = item.ty else {
            wasmtime::bail!("Expected a native skill interface");
        };
        let mut instance = linker.instance(import)?;
        for (method, export) in api.exports(engine) {
            wasmtime::ensure!(
                identifier(method) && matches!(export.ty, ComponentItem::ComponentFunc(_)),
                "Invalid native skill method"
            );
            let operation = format!("{skill}.{method}");
            instance.func_wrap(
                method,
                move |mut store: StoreContextMut<Host>,
                      (arguments,): (String,)|
                      -> wasmtime::Result<Reply> {
                    Ok(store
                        .data_mut()
                        .request("skill", &operation, json!([arguments])))
                },
            )?;
        }
    }
    Ok(())
}
