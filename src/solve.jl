#############################################################################
# JuMPeR
# Julia for Mathematical Programming - extension for Robust Optimization
# See http://github.com/IainNZ/JuMPeR.jl
#############################################################################
# solve.jl
# All the logic for solving robust optimization problems. Communicates with
# oracles to build and solve the robust counterpart.
#############################################################################

function solveRobust(rm::Model; report=false, args...)
    
    robdata = getRobust(rm)

    # Create master problem, a normal JuMP model
    # TODO: make a copy of certain things
    # TODO: Do we even need to make a copy anymore?
    start_time = time()
    master = Model(solver=rm.solver)
    master.objSense  = rm.objSense
    master.obj       = rm.obj  # For now, only certain obj
    master.linconstr = rm.linconstr
    master.numCols   = rm.numCols
    master.colNames  = rm.colNames
    master.colLower  = rm.colLower
    master.colUpper  = rm.colUpper
    master.colCat    = rm.colCat
    mastervars       = [Variable(master, i) for i = 1:rm.numCols]
    master_init_time = time() - start_time
    num_unccons      = length(robdata.uncertainconstr)

    # As a more general question, need to figure out a principled way of putting
    # box around original solution, or doing something when original solution is unbounded.
    for j in 1:master.numCols
        master.colLower[j] = max(master.colLower[j], -10000)
        master.colUpper[j] = min(master.colUpper[j], +10000)
    end

    # Some constraints may not have oracles, so we will create a default
    # PolyhedralOracle that is shared amongst them.
    # Register the constraints with their oracles
    oracle_register_time = time()
    prefs = Dict()
    for (name,value) in args
        prefs[name] = value
    end
    default_oracle = PolyhedralOracle()
    for ind in 1:num_unccons
        c = robdata.uncertainconstr[ind]
        w = robdata.oracles[ind]
        if w == nothing
            w = default_oracle
            robdata.oracles[ind] = default_oracle
        end
        registerConstraint(w, c, ind, prefs)
    end
    oracle_register_time = time() - oracle_register_time


    # Give oracles time to do any setup
    oracle_setup_time = time()
    for ind in 1:num_unccons
        setup(robdata.oracles[ind], rm)
    end
    oracle_setup_time = time() - oracle_setup_time

    # For oracles that want/have to reformulate, process them now
    reform_time = time()
    reformed_cons = 0
    for ind = 1:num_unccons
        if generateReform(robdata.oracles[ind], rm, ind, master)
            reformed_cons += 1
        end
    end
    reform_time = time() - reform_time

    # Begin main solve loop
    cutting_rounds  = 0
    cuts_added      = 0
    master_time     = 0
    cut_time        = 0
    while true
        cutting_rounds += 1
        
        # Solve master
        tic()
        master_status = solve(master)
        master_time += toq()

        # Generate cuts
        cut_added = false
        tic()
        for ind = 1:num_unccons
            num_cuts_added = generateCut(robdata.oracles[ind], rm, ind, master)
            if num_cuts_added > 0
                cut_added = true
                cuts_added += num_cuts_added
            end
        end
        cut_time += toq()

        # Terminate solve loop when no more cuts added
        if !cut_added
            break
        end
    end

    # Return solution
    total_time = time() - start_time
    rm.colVal = master.colVal
    rm.objVal = master.objVal

    # Report if request
    if report
        println("Solution report")
        #println("Prefered method: $(preferred_mode==:Cut ? "Cuts" : "Reformulations")")
        println("Uncertain Constraints:")
        println("  Reformulated     $reformed_cons")
        println("  Cutting plane    $(length(robdata.uncertainconstr) - reformed_cons)")
        println("  Total            $(length(robdata.uncertainconstr))")
        println("Cutting rounds:  $cutting_rounds")
        println("Total cuts:      $cuts_added")
        println("Overall time:    $total_time")
        println("  Master init      $master_init_time")
        println("  Oracle setup     $oracle_setup_time")
        println("  Reformulation    $reform_time")
        println("  Master solve     $master_time")
        println("  Cut solve&add    $cut_time")
    end

end