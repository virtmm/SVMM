unless Node.alive?() do
  Node.start(:"grpc_test_node@127.0.0.1", name_domain: :longnames)
end

ExUnit.start()
