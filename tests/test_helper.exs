temp_dir = Application.fetch_env!(:mirror_neuron, :temp_dir)
System.put_env("MIRROR_NEURON_TEMP_DIR", temp_dir)
File.mkdir_p!(temp_dir)
ExUnit.start()
