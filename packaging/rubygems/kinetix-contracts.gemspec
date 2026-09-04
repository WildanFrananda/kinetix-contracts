Gem::Specification.new do |spec|
  spec.name        = "kinetix-contracts"
  spec.version     = "__VERSION__"
  spec.summary     = "Kinetix wire contracts"
  spec.description = "Generated from kinetix-contracts. Do not edit."
  spec.authors     = ["Kinetix"]
  spec.files       = Dir["**/*.rb"]
  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "google-protobuf", "~> 4.29"
  spec.add_dependency "grpc", "~> 1.67"
end
