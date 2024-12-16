# Code based on https://github.com/kprotty/zig-adaptive-lock
using Statistics
using TypedTables
function work_unit(n_iter)
    for _ in 1:n_iter
        ccall(:jl_cpu_pause, Cvoid, ())
    end
end

function nanos_per_unit()
    attempts = zeros(1000)
    num_work = 100000
    for i in eachindex(attempts)
        start = time_ns()
        work_unit(num_work)
        stop = time_ns()
        attempts[i] = (stop - start)/num_work
    end
    return mean(attempts)
end

mutable struct Barrier
    @atomic on::Bool
    cond::Threads.Event
end

function Barrier(on::Bool)
    return Barrier(on, Threads.Event())
end

function is_running(b::Barrier)
    return @atomic :acquire b.on
end

@kwdef struct BenchConfig
    n_tasks::Int = Threads.nthreads()
    time_locked_max::Int = 50 # Time in ns
    time_locked_min::Int = 25# Time in ns
    time_unlocked_max::Int = 50# Time in ns
    time_unlocked_min::Int = 25# Time in ns
    runtime::Int = 500 #Time in ms
end

struct WorkConfig
    max_iters::UInt
    min_iters::UInt
end

function WorkConfig(max_iters::Int, min_iters::Int)
    if max_iters < min_iters
        throw(ArgumentError("max_iters must be greater than min_iters"))
    end
    if max_iters == min_iters
        max_iters += 1
    end
    return WorkConfig(max_iters, min_iters)
end

mutable struct TaskReport
    niters::Int
    latencies::Vector{Int}
end

struct BenchResult
    report::Vector{TaskReport}
    config::BenchConfig
    lock::DataType
end

function wrapper(lock::Base.AbstractLock, report::TaskReport, barrier::Barrier, locked::WorkConfig, unlocked::WorkConfig)
    @noinline take_locks(lock, report, barrier, locked, unlocked)
end

function take_locks(l::Base.AbstractLock, report::TaskReport, barrier::Barrier, locked::WorkConfig, unlocked::WorkConfig)
    niter = 0
    latencies = UInt[]
    sizehint!(latencies, 100000)
    locked_iters = 0
    unlocked_iters = 0
    wait(barrier.cond)
    while is_running(barrier)
        if niter % 32 == 0
            locked_iters = rand(locked.min_iters:locked.max_iters)
            unlocked_iters = rand(unlocked.min_iters:unlocked.max_iters)
            if niter % 10240 == 0
                yield() # Succesfully taking locks doesn't yield so we need to guarantee progress on other tasks
            end
        end
        work_unit(unlocked_iters)
        acquire_begin = time_ns()
        acquire_end = 0
        @lock l begin
            acquire_end = time_ns()
            work_unit(locked_iters)
        end
        push!(latencies, acquire_end - acquire_begin)
        niter += 1
    end
    report.niters = niter
    report.latencies = latencies
    nothing
end

function bench(_::Type{T}, config::BenchConfig) where T <: Base.AbstractLock
    t = Threads.@spawn _bench(T, config)
    fetch(t)
end


function _bench(_::Type{T}, config::BenchConfig) where T <: Base.AbstractLock
    lock = T()
    barrier = Barrier(false)
    task_reports = [TaskReport(0, UInt[]) for _ in 1:config.n_tasks]
    nanos = nanos_per_unit()
    locked = WorkConfig(round(UInt, config.time_locked_max/nanos), round(UInt, config.time_locked_min/nanos))
    unlocked = WorkConfig(round(UInt, config.time_unlocked_max/nanos), round(UInt, config.time_unlocked_min/nanos))
    ts = Task[]
    for i in 1:config.n_tasks
        push!(ts, Threads.@spawn wrapper(lock, task_reports[i], barrier, locked, unlocked))
    end
    @atomic :release barrier.on = true
    sleep(0.3) #too lazy to implement proper synchronization here
    notify(barrier.cond)
    sleep(config.runtime/1000)
    @atomic :release barrier.on = false
    for t in ts
        fetch(t)
    end
    return BenchResult(task_reports, config, T)
end

function analyze(result::BenchResult)
    task_reports = result.report
    niters = 0
    latencies = UInt[]
    for report in task_reports
        niters += report.niters
        append!(latencies, report.latencies)
    end
    mean_iters = mean([report.niters for report in task_reports])
    max_iters = maximum([report.niters for report in task_reports])
    min_iters = minimum([report.niters for report in task_reports])
    std_dev = std([report.niters for report in task_reports])
    percentiles = [quantile(latencies, p) for p in [0.5, 0.99]]
    (lock=result.lock,n_tasks=result.config.n_tasks, mean_iters=mean_iters, max_iters=max_iters, min_iters=min_iters, std_dev=std_dev, sum=niters, percentiles=(0.5=>percentiles[1], 0.99=>percentiles[2]),
    time_locked_ns=(result.config.time_locked_min, result.config.time_locked_max), time_unlocked_ns = (result.config.time_unlocked_min, result.config.time_unlocked_max), runtime_ms=result.config.runtime)
end


if !isinteractive()
    t = Threads.@spawn :interactive begin
        res = []
        config = BenchConfig(n_tasks=2, time_locked_max=11, time_locked_min=10, time_unlocked_max=11, time_unlocked_min=10, runtime=500)
        push!(res, analyze(bench(ReentrantLock, config)))
        push!(res, analyze(bench(Threads.SpinLock, config)))
        config = BenchConfig(n_tasks=4, time_locked_max=11, time_locked_min=10, time_unlocked_max=11, time_unlocked_min=10, runtime=500)
        push!(res, analyze(bench(ReentrantLock, config)))
        push!(res, analyze(bench(Threads.SpinLock, config)))
        config = BenchConfig(n_tasks=8, time_locked_max=11, time_locked_min=10, time_unlocked_max=11, time_unlocked_min=10, runtime=500)
        push!(res, analyze(bench(ReentrantLock, config)))
        push!(res, analyze(bench(Threads.SpinLock, config)))
        config = BenchConfig(n_tasks=2, time_locked_max=11, time_locked_min=10, time_unlocked_max=101, time_unlocked_min=100, runtime=500)
        push!(res, analyze(bench(ReentrantLock, config)))
        push!(res, analyze(bench(Threads.SpinLock, config)))
        config = BenchConfig(n_tasks=4, time_locked_max=11, time_locked_min=10, time_unlocked_max=101, time_unlocked_min=100, runtime=500)
        push!(res, analyze(bench(ReentrantLock, config)))
        push!(res, analyze(bench(Threads.SpinLock, config)))
        config = BenchConfig(n_tasks=8, time_locked_max=11, time_locked_min=10, time_unlocked_max=101, time_unlocked_min=100, runtime=500)
        push!(res, analyze(bench(ReentrantLock, config)))
        push!(res, analyze(bench(Threads.SpinLock, config)))
        config = BenchConfig(n_tasks=2, time_locked_max=500, time_locked_min=10, time_unlocked_max=1001, time_unlocked_min=1000, runtime=500)
        push!(res, analyze(bench(ReentrantLock, config)))
        push!(res, analyze(bench(Threads.SpinLock, config)))
        config = BenchConfig(n_tasks=4, time_locked_max=500, time_locked_min=10, time_unlocked_max=1001, time_unlocked_min=1000, runtime=500)
        push!(res, analyze(bench(ReentrantLock, config)))
        push!(res, analyze(bench(Threads.SpinLock, config)))
        config = BenchConfig(n_tasks=8, time_locked_max=500, time_locked_min=10, time_unlocked_max=1001, time_unlocked_min=1000, runtime=500)
        push!(res, analyze(bench(ReentrantLock, config)))
        push!(res, analyze(bench(Threads.SpinLock, config)))
        display(Table(row for row in res))
    end
    fetch(t)
end