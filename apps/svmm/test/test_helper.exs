ekv_dir = Application.get_env(:svmm, :ekv_data_dir)

if ekv_dir do
  File.rm_rf!(ekv_dir)
end

unless Node.alive?() do
  Node.start(:"test_node@127.0.0.1", name_domain: :longnames)
end

ExUnit.start()
