# Simple Virtual Machine Manager

The server application for the Simple Virtual Machine Manager (SVMM). It interacts with the agent using protobuf over gRPC.

It is an Elixir application that has internal applications, under an umbrella app.

1. Web interface (svmm_web)
2. Communications using grpc (svmm_grpc)
3. Core (svmm)

Each application has its own supervision tree.

## Installation

Clone your code from  <https://github.com/virtmm>

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Umbrella project

This is an Elixir umbrella project. It is composed of multiple apps:

* [Svmm](apps/svmm) - The core logic
* [SvmmWeb](apps/svmm_web) - The Phoenix web interface
* [SvmmGrpc](apps/svmm_grpc) - The gRPC transport adapter

Each app has its own README and configuration.

## Learn more

* Official website: <https://www.phoenixframework.org/>
* Guides: <https://phoenix.hexdocs.pm/overview.html>
* Docs: <https://phoenix.hexdocs.pm>
* Forum: <https://elixirforum.com/c/phoenix-forum>
* Source: <https://github.com/phoenixframework/phoenix>
