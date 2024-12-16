# Benchmark for locks in julia

# The default run goes up to 8 tasks/threads but this can be customizable using the BenchConfig struct

# The benchmark is run using the following command:
# ```julia
# julia --project -t 8 -e 'using Pkg; Pkg.instantiate(); include("benchmarks/locks.jl")'
