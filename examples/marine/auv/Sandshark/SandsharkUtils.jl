# utility functions needed for sandshark

using DelimitedFiles
using Interpolations
using ProgressMeter



# Accumulate delta X values using FGOS
# TODO, refactor into RoME
function devAccumulateOdoPose2(DX::Array{Float64,2},
                               X0::Vector{Float64}=zeros(3);
                               P0=1e-3*Matrix(LinearAlgebra.I, 3,3),
                               Qc=1e-6*Matrix(LinearAlgebra.I, 3,3),
                               dt::Float64=1.0  )
  #
  # entries are rows with columns dx,dy,dtheta
  @assert size(DX,2) == 3
  mpp = MutablePose2Pose2Gaussian(MvNormal(X0, P0) )
  nXYT = zeros(size(DX,1), 3)
  for i in 1:size(DX,1)
    RoME.accumulateDiscreteLocalFrame!(mpp,DX[i, :],Qc,dt)
    nXYT[i,:] .= mpp.Zij.μ
  end

  return nXYT
end




@enum SolverStateMachine SSMReady SSMConsumingSolvables SSMSolving


datadir = joinpath(ENV["HOME"],"data","sandshark","full_wombat_2018_07_09","extracted")
matcheddir = joinpath(datadir, "matchedfilter", "particles")
beamdir = joinpath(datadir, "beamformer", "particles")

function loaddircsvs(datadir)
  # https://docs.julialang.org/en/v0.6.1/stdlib/file/#Base.Filesystem.walkdir
  datadict = Dict{Int, Array{Float64}}()
  for (root, dirs, files) in walkdir(datadir)
    # println("Files in $root")
    for file in files
      # println(joinpath(root, file)) # path to files
      data = readdlm(joinpath(root, file),',')
      datadict[parse(Int,split(file,'.')[1])/1] = data
    end
  end
  return datadict
end

rangedata = loaddircsvs(matcheddir)
azidata = loaddircsvs(beamdir)
timestamps = intersect(sort(collect(keys(rangedata))), sort(collect(keys(azidata))))


# NAV data
navdata = Dict{Int, Vector{Float64}}()
navfile = readdlm(joinpath(datadir, "nav_data.csv"))
for row in navfile
    s = split(row, ",")
    id = round(Int, 1e9*parse(Float64, s[1]))
    # round(Int, 1000 * parse(s[1])) = 1531153292381
    navdata[id] = parse.(Float64,s)
end
navkeys = sort(collect(keys(navdata)))
# NAV colums are X,Y = 7,8
# lat,long = 9,10
# time,pitch,roll,heading,speed,[Something], internal_x,internal_y,internal_lat,internal_long, yaw_rad

# LBL data - note the timestamps need to be exported as float in future.
lbldata = Dict{Int,  Vector{Float64}}()
lblfile = readdlm(joinpath(datadir, "lbl.csv"))
for row in lblfile
    s = split(row, ",")
    id = round(Int, 1e9*parse(Float64, s[1]))
    if s[2] != "NaN"
        lbldata[id] = parse.(Float64, s)
    end
end
lblkeys = sort(collect(keys(lbldata)))



# function heading2yaw(heading)
# heading = map( x->deg2rad(navdata[x][4]), navkeys )
# wrapheading = TU.wrapRad.(heading)
# end

# GET Y = north,  X = East,  Heading along +Y clockwise [0,360)]
# east = Float64[]
# north = Float64[]
# heading = Float64[]

# WANT X = North,  Y = West,  Yaw is right and rule from +X (0) towards +Y pi/2, [-pi,pi)
# so the drawPoses picture will look flipped from Nicks picture
# remember theta = atan2(y,x)    # this is right hand rule
X = Float64[]
Y = Float64[]
yaw = Float64[]
for id in navkeys
  # push!(east, getindex(navdata[id],7)) # x-column csv
  # push!(north, getindex(navdata[id],8)) # y-column csv
  # push!(heading, getindex(navdata[id],4))
  # push!(yaw, TU.wrapRad(-deg2rad(getindex(navdata[id],4))))

  push!(X, 0.7*getindex(navdata[id],7) ) # 8
  push!(Y, 0.7*getindex(navdata[id],8) ) # 7
  push!(yaw, TU.wrapRad(pi/2-deg2rad(getindex(navdata[id],4))) )  # rotation about +Z
end

lblX = Float64[]
lblY = Float64[]
for id in lblkeys
    push!(lblX, getindex(lbldata[id],2) )
    push!(lblY, getindex(lbldata[id],3) )
end

# Build interpolators for x, y, yaw
interp_x = LinearInterpolation(navkeys, X)
interp_y = LinearInterpolation(navkeys, Y)
interp_yaw = LinearInterpolation(navkeys, yaw)



function poorMansDeconv_BF(XX = collect(range(-pi,pi,length=1000)),
                           YY = ppbrDict[epochs[1]].bearing(XX)      )
  #
  YY1 = YY.^4
  YY1 ./= maximum(YY1)
  YY2 = YY1.^4
  YY2 ./= maximum(YY2)
  # Gadfly.plot(x=XX, y=YY2, Geom.line)
  bss = AliasingScalarSampler(XX, YY2)
  pts = reshape(rand(bss, 200), 1, :)
  pc = manikde!(pts, Sphere1)
  # plotKDECircular(pc)

  return pc
end




# Step: Selecting a subset for processing and build up a cache of the factors.

function doEpochs(timestamps, rangedata, azidata, interp_x, interp_y, interp_yaw, odonoise; TSTART=356, TEND=1200, SNRfloor::Float64=0.6, STRIDE::Int=4)
  #
  ## Caching factors
  ppbrDict = Dict{Int, Pose2Point2BearingRange}()
  ppbDict = Dict{Int, Pose2Point2Bearing}()
  pprDict = Dict{Int, Pose2Point2Range}()
  odoDict = Dict{Int, Pose2Pose2}()
  NAV = Dict{Int, Vector{Float64}}()

  XX = collect(range(-pi,pi,length=1000))

  epochs = timestamps[TSTART:STRIDE:TEND]
  lastepoch = 0
  @showprogress "preparing data" for ep in epochs
    # @show ep
    if lastepoch != 0
      # @show interp_yaw(ep)
      deltaAng = interp_yaw(ep) - interp_yaw(lastepoch)

      wXi = TU.SE2([interp_x(lastepoch);interp_y(lastepoch);interp_yaw(lastepoch)])
      wXj = TU.SE2([interp_x(ep);interp_y(ep);interp_yaw(ep)])
      iDXj = se2vee(wXi\wXj)
      NAV[ep] = iDXj
      # NAV[ep][1:2] .*= 0.7
      # println("$(iDXj[1]), $(iDXj[2]), $(iDXj[3])")

      odoDict[ep] = Pose2Pose2(MvNormal(NAV[ep], odonoise) )
    end
    rangepts = rangedata[ep][:]
    rangeprob = kde!(rangepts)

    # azipts = azidata[ep][:,1]
    azipts = collect(azidata[ep][:,1:1]')
    aziptsw = TU.wrapRad.(azipts)

    # direct
    aziprobl = kde!(azipts)
    # npts = rand(aziprobl, 200)
    # aziprob = manikde!(npts, Sphere1)

    # with deconv
    aziprob = poorMansDeconv_BF(XX, aziprobl(XX))

    # alternative range probability
    rawmf = readdlm("/home/dehann/data/sandshark/full_wombat_2018_07_09/extracted/matchedfilter/raw/$(ep).csv",',')
    dvmf = exp.(rawmf[:,2])
    dvmf .= dvmf.^4
    dvmf ./= cumsum(dvmf)[end]
    dvmf .= dvmf.^2
    dvmf ./= cumsum(dvmf)[end]
    range_bss = AliasingScalarSampler(rawmf[:,1], dvmf, SNRfloor=SNRfloor) # exp.(rawmf[:,2])

    # prep the factor functions
    ppbrDict[ep] = Pose2Point2BearingRange(aziprob, range_bss) # rangeprob
    ppbDict[ep] = Pose2Point2Bearing(aziprob) # rangeprob
    pprDict[ep] = Pose2Point2Range(range_bss) # rangeprob
    lastepoch = ep
  end
  return epochs, odoDict, ppbrDict, ppbDict, pprDict, NAV
end


function initializeAUV_noprior(dfg::AbstractDFG,
                               dashboard::Dict;
                               stride_range::Int=4,
                               magStdDeg::Float64=5.0,
                               stride_solve::Int=10 )
  #
  addVariable!(dfg, :x0, Pose2)

  # Pinger location is [17; 1.8]
  addVariable!(dfg, :l1, Point2, solvable=0)
  beaconprior = PriorPoint2( MvNormal([17; 1.8], Matrix(Diagonal([0.1; 0.1].^2)) ) )
  addFactor!(dfg, [:l1], beaconprior, autoinit=true, solvable=0)

  addVariable!(dfg, :drt_0, Pose2, solvable=0)
  drec = MutablePose2Pose2Gaussian(MvNormal(zeros(3), Matrix{Float64}(LinearAlgebra.I, 3,3)))
  addFactor!(dfg, [:x0; :drt_0], drec, solvable=0, autoinit=false)

  # reference odo solution
  addVariable!(dfg, :drt_ref, Pose2, solvable=0)
  drec = MutablePose2Pose2Gaussian(MvNormal(zeros(3), Matrix{Float64}(LinearAlgebra.I, 3,3)))
  addFactor!(dfg, [:x0; :drt_ref], drec, solvable=0, autoinit=false)
  dashboard[:drtOdoRef] = (:x0, :drt_ref, drec)

  # store current real time tether factor
  dashboard[:drtMpp] = Dict{Symbol,MutablePose2Pose2Gaussian}(:x0 => drec)
  dashboard[:drtCurrent] = (:x0, :drt_0)
  # standard odo process noise levels
  # TODO, debug and refine cont2disc
  dashboard[:Qc_odo] = Diagonal([0.01;0.01;0.001].^2) |> Matrix

  dashboard[:odoTime] = unix2datetime(0)
  dashboard[:poseRate] = Second(1)
  dashboard[:lastPose] = :x0

  dashboard[:solvables] = Channel{Vector{Symbol}}(100)

  dashboard[:loopSolver] = true

  dashboard[:SOLVESTRIDE] = stride_solve # add a range measurement every xth pose
  dashboard[:poseStride] = 0
  dashboard[:canTakePoses] = HSMReady
  dashboard[:solveInProgress] = SSMReady

  dashboard[:poseSolveToken] = Channel{Symbol}(3)

  dashboard[:RANGESTRIDE] = stride_range # add a range measurement every xth pose
  dashboard[:rangesBuffer] = CircularBuffer{Tuple{DateTime, Array{Float64,2}, Vector{Bool}}}(dashboard[:RANGESTRIDE]+4)
  dashboard[:rangeCount] = 0

  dashboard[:SNRfloor] = 0.6

  dashboard[:realTimeSlack] = Millisecond(0)

  dashboard[:magBuffer] = CircularBuffer{Tuple{DateTime, Float64, Vector{Bool}}}(20)
  dashboard[:magNoise] = deg2rad(magStdDeg)

  dashboard[:lblBuffer] = CircularBuffer{Tuple{DateTime, Array{Float64,1}, Vector{Bool}}}(dashboard[:RANGESTRIDE]+4)

  dashboard[:odoCov] = Matrix{Float64}(Diagonal([0.5;0.3;0.2].^2))

  nothing
end


function manageSolveTree!(dfg::AbstractDFG, dashboard::Dict; dbg::Bool=false)

  @info "logpath=$(getLogPath(dfg))"
  getSolverParams(dfg).drawtree = true
  getSolverParams(dfg).qfl = 3*dashboard[:SOLVESTRIDE]
  getSolverParams(dfg).isfixedlag = true
  getSolverParams(dfg).limitfixeddown = true

  # allow async process
  # getSolverParams(dfg).async = true

  # prep with empty tree
  tree = emptyBayesTree()

  # needs to run asynchronously
  ST = @async begin
    while @show length(ls(dfg, :x0, solvable=1)) == 0
      "waiting for prior on x0" |> println
      sleep(1)
    end
    # keep solving
    while dashboard[:loopSolver]
      # add any newly solvables (atomic)
      while !isready(dashboard[:solvables]) && dashboard[:loopSolver]
        sleep(0.5)
      end

      # adjust latest RTT after solve, latest solved
      lastSolved = sortDFG(ls(dfg, r"x\d", solvable=1))[end]
      dashboard[:drtCurrent] = (lastSolved, Symbol("drt_"*string(lastSolved)[2:end]))

      #add any new solvables
      while isready(dashboard[:solvables]) && dashboard[:loopSolver]
        dashboard[:solveInProgress] = SSMConsumingSolvables
        @show tosolv = take!(dashboard[:solvables])
        for sy in tosolv
          # setSolvable!(dfg, sy, 1) # see DFG #221
          # TODO temporary workaround
          getfnc = occursin(r"f", string(sy)) ? getFactor : getVariable
          getfnc(dfg, sy).solvable = 1
        end
      end

      @info "Ensure all new variables initialized"
      ensureAllInitialized!(dfg)

      dashboard[:solveInProgress] = SSMReady

      # solve only every 10th pose
      if 0 < length(dashboard[:poseSolveToken].data)
      # if 10 <= dashboard[:poseStride]
        @info "reduce problem size by disengaging older parts of factor graph"
        setSolvableOldPoses!(dfg, youngest=getSolverParams(dfg).qfl+dashboard[:SOLVESTRIDE], oldest=100, solvable=0)

        # set up state machine flags to allow overlapping or block
        dashboard[:solveInProgress] = SSMSolving
        # dashboard[:poseStride] = 0

        # do the actual solve (with debug saving)
        lasp = getLastPoses(dfg, filterLabel=r"x\d", number=1)[1]
        !dbg ? nothing : saveDFG(dfg, joinpath(getLogPath(dfg), "fg_before_$(lasp)"))
        tree, smt, hist = solveTree!(dfg, tree)
        !dbg ? nothing : saveDFG(dfg, joinpath(getLogPath(dfg), "fg_after_$(lasp)"))

        # unblock LCMLog reader for next STRIDE segment
        dashboard[:solveInProgress] = SSMReady
        # de-escalate handler state machine
        dashboard[:canTakePoses] = HSMHandling

        # remove a token to allow progress to continue
        gotToken = take!(dashboard[:poseSolveToken])
        "end of solve cycle, token=$gotToken" |> println
      else
        "sleep a solve cycle" |> println
        sleep(0.2)
      end
    end
  end
  return ST
end








#