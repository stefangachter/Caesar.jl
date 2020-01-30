
# using Revise

using ArgParse
using Caesar, RoME, DistributedFactorGraphs
using DelimitedFiles
using DSP
using Dates
using Glob


include(joinpath(@__DIR__, "CommonUtils.jl"))

#DUPLICATE DEFINITION
# @enum SolverStateMachine SSMReady SSMConsumingSolvables SSMSolving
# @enum HandlerStateMachine HSMReady HSMHandling HSMOverlapHandling HSMBlocking

function parse_commandline()
    s = ArgParseSettings()

    @add_arg_table s begin
        # "--kappa_odo"
        #     help = "Scale the odometry covariance"
        #     arg_type = Float64
        #     default = 1.0
        "--plotSeriesBeliefs"
            help = "Glob fg_* archives and draw belief frames as many as is requested, default 0 is for all"
            arg_type = Int
            default = 0
        "--reportPoses"
            help = "Generate report on interpose pose factors"
            action = :store_true
        "--reportRanges"
            help = "Generate report on range factors"
            action = :store_true
        "--drawAllRanges"
            help = "Draw ranges as separate images"
            action = :store_true
        "--skip"
            help = "Skip existing images"
            action = :store_true
        "--drawFG"
            help = "Draw factor graph to PDF"
            action = :store_true
        "reportDir"
            help = "which folder in which to produce results."
            required = false
    end

    return parse_args(s)
end

pargs = if !isdefined(Main, :parsed_args)
  parse_commandline()
else
  parsed_args
end

# pargs["reportDir"] = "/tmp/caesar/2020-01-23T13:36:12.392/fg_after_x381.tar.gz"
# pargs["reportDir"] = "/media/dehann/temp2/caesar/2020-01-26T20:36:57.456/fg_after_x321.tar.gz"
# pargs["reportDir"] = "/tmp/caesar/2020-01-27T01:46:52.871/fg_after_x1181.tar.gz"

if !haskey(pargs, "reportDir") && isdefined(Main, :fg)
  pargs["reportDir"] = getLogPath(fg)
end

include(joinpath(@__DIR__, "Plotting.jl"))

# @show pargs["reportDir"]
# @show splitpath(pargs["reportDir"])

# load the factor graph needed
fg = if !isdefined(Main, :fg)
  println("going to load fg")
  fg = LightDFG{SolverParams}(params=SolverParams())
  @show pathElem = splitpath(pargs["reportDir"])
  @show getSolverParams(fg).logpath = joinpath(pathElem[1:end-1]...)
  loadDFG(pargs["reportDir"], Main, fg)
  fg
else
  fg
end

wtdsh = if !isdefined(Main, :wtdsh)
  # load wtdsh and dashboard
  @show wtFile = string(joinLogPath(fg, "dash.json"))
  wtdshA = readdlm(joinLogPath(fg, "dash.csv"), ',')
  # make array of array
  wtdsh = []
  for i in 1:size(wtdshA,1)
    push!(wtdsh, wtdshA[i,:])
  end
  wtdsh
else
  wtdsh
end



## draw fg
if pargs["drawFG"]
  drawGraph(fg, filepath=joinpath(getLogPath(fg),"fg.pdf"), show=false, engine="sfdp")
end


##  Draw trajectory & Analyze solve run

plb = plotSandsharkFromDFG(fg, drawTriads=false)
plb |> PDF(joinpath(getLogPath(fg),"traj.pdf"))
# pla = drawPosesLandmarksAndOdo(fg, ppbrDict, navkeys, X, Y, lblkeys, lblX, lblY)


plc = plotFrontendTiming(wtdsh)
plc |> PDF(joinpath(getLogPath(fg),"timing.pdf"),75cm,25cm)
# accumulated real time slack
wtt = (x->x[6]).(wtdsh)
wtt[end]




# set all to solvable=1

map(x->setSolvable!(fg, x, 1), setdiff(ls(fg), ls(fg, r"drt_\d")))
map(x->setSolvable!(fg, x, 1 ),[lsf(fg, Pose2Pose2);
                                lsf(fg, Pose2Point2Range);
                                lsfPriors(fg)] )


# Check how long not solvable tail is?
# map(x->(x,isSolvable(getVariable(fg,x))), getLastPoses(fg, filterLabel=r"x\d", number=15))


# after all initialized
plb = plotSandsharkFromDFG(fg, drawTriads=false, lbls=false)


## add reference layer
posesyms = ls(fg, r"x\d") |> sortDFG
filter!(x->isInitialized(fg, x), posesyms)
filter!(x->solverData(getVariable(fg, x), :lbl) != nothing, posesyms)
XX = (x->(solverData(getVariable(fg, x), :lbl).val[1,1])).(posesyms)
YY = (x->(solverData(getVariable(fg, x), :lbl).val[2,1])).(posesyms)
pl = Gadfly.layer(x=XX, y=YY, Geom.path, Theme(default_color=colorant"magenta"))
union!(plb.layers, pl)
plb |> PDF(joinLogPath(fg,"traj_ref.pdf"))







## plot the DEAD RECKON THREAD


function loadResultsDRT(fg)
  drt_data = readdlm(joinLogPath(fg, "DRT.csv"), ',')

  DRTT = DateTime.(drt_data[:,1])
  XX = Float64.(drt_data[:,4])
  YY = Float64.(drt_data[:,5])

  # filter the signals for hard jumps between drt transitions
  responsetype = Lowpass(1.0; fs=50)
  designmethod = FIRWindow(hanning(64))

  # remove those near zero
  mask = 40.0 .< (XX.^2 + YY.^2)

  TTm = DRTT[mask]
  XXm = XX[mask]
  YYm = YY[mask]
  XXf = filt(digitalfilter(responsetype, designmethod), XXm)
  YYf = filt(digitalfilter(responsetype, designmethod), YYm)

  return drt_data, TTm, XXm, YYm, XXf, YYf
end

drt_data, TTm, XXm, YYm, XXf, YYf = loadResultsDRT(fg)

mask = YYf .< -32
XXfm = XXf[mask]
YYfm = YYf[mask]
# only start does not match
TTmm = sum(mask)<length(TTm) ? TTm[end-sum(mask)+1:end] : TTm

# plot DRT
pl = Gadfly.plot(x=XXm[1:10:end], y=YYm[1:10:end], Geom.point, Theme(default_color=colorant"khaki"))
pl |> PDF(joinLogPath(fg,"drt.pdf"))
pl = Gadfly.plot(x=XXf[1:10:end], y=YYf[1:10:end], Geom.point, Theme(default_color=colorant"green"))
pl |> PDF(joinLogPath(fg,"drtf.pdf"))

pl = Gadfly.layer(x=XXfm, y=YYfm, Geom.path, Theme(default_color=colorant"green"))
union!(plb.layers, pl)
pl = Gadfly.layer(x=XXm[mask], y=YYm[mask], Geom.path, Theme(default_color=colorant"khaki"))
union!(plb.layers, pl)
plb |> PDF(joinLogPath(fg,"traj_ref_drt.pdf"))






odo_data = readdlm(joinLogPath(fg, "ODO.csv"), ',')

XX = Float64.(odo_data[:,3])
YY = Float64.(odo_data[:,4])

# remove those near zero
mask = 40.0 .< (XX.^2 + YY.^2)

XXf = XX #[mask]
YYf = YY #[mask]

pl = Gadfly.plot(x=XXf[1:10:end], y=YYf[1:10:end], Geom.point, Theme(default_color=colorant"black"))
pl |> PDF(joinLogPath(fg,"odo.pdf"))

pl = Gadfly.layer(x=XXf, y=YYf, Geom.path, Theme(default_color=colorant"black"))
union!(plb.layers, pl)
plb |> PDF(joinLogPath(fg,"traj_ref_drt_odo.pdf"))








odo_data = readdlm(joinLogPath(fg, "RAWODO.csv"), ',')

DX = Float64.(odo_data[:,3:5])

nXYT = devAccumulateOdoPose2(DX, getFactorType(getFactor(fg, :x0f1)).Z.μ)

# remove those near zero for better visualization
mask = 40.0 .< (nXYT[:,1].^2 + nXYT[:,2].^2)

XXf = nXYT[:,1][mask]
YYf = nXYT[:,2][mask]

# pl = Gadfly.plot(x=XXf, y=YYf, Geom.path, Theme(default_color=colorant"black"))
pl = plotTrajectoryArrayPose2(nXYT)
pl |> PDF(joinLogPath(fg,"dirodo.pdf"))

pl = Gadfly.layer(x=XXf, y=YYf, Geom.path, Theme(default_color=colorant"black"))
union!(plb.layers, pl)
plb |> PDF(joinLogPath(fg,"traj_ref_drt_dirodo.pdf"))



## plot densities


include(joinpath(@__DIR__, "MakiePlotsFG.jl"))


# nvsyms = ls(fg, r"x\d") |> length

# how to suppress window and simply export
pl = plotVariableBeliefs(fg, r"x\d", sortVars=true, fade=15, fadeFloor=0.2, resolution=(1920,1080))
# pl |> typeof |> fieldnames


Base.rm(joinLogPath(fg,"fgBeliefs.png"), force=true)
Makie.save(joinLogPath(fg,"fgBeliefs.png"), pl)


# pargs["plotSeriesBeliefs"] = 3
0

# plot a series of frames
if 0 <= pargs["plotSeriesBeliefs"]

files = glob("fg_x*.tar.gz", getLogPath(fg))
indiv = splitpath.(files) .|> x->x[end]
# reduce the number of frames, if requested
indiv = pargs["plotSeriesBeliefs"] == 0 ? indiv : indiv[1:pargs["plotSeriesBeliefs"]]
# get range from last file in glob
fgl = LightDFG{SolverParams}(params=SolverParams())
loadDFG(joinLogPath(fg, indiv[end]), Main, fgl)
drt_data, TTm, XXm, YYm, XXf, YYf = loadResultsDRT(fg)
minmax = getRangeCartesian(fgl,r"x\d",digits=-1)
xmin=minmax[1,1]-10;xmax=minmax[1,2]+10;ymin=minmax[2,1]-10;ymax=minmax[2,2]+10;
Base.mkpath(joinLogPath(fg, "frames"))
Base.mkpath(joinLogPath(fg, "lines"))
global frame = 0
for ind in indiv
  global frame += 1
  println("frame $frame of $(length(indiv))")
  fname = split(ind, '.')[1]
  if pargs["skip"] && isfile(joinLogPath(fg,"frames/$fname.png")) && isfile(joinLogPath(fg,"lines/$fname.png"))
    @info "skip $fname since its already there"
    continue
  end
  fgl = LightDFG{SolverParams}(params=SolverParams())
  loadDFG(joinLogPath(fg, ind), Main, fgl)
  nvars = length(ls(fgl, r"x\d"))
  # if nvars < 15
  #   continue
  # end
  try
    pl = plotVariableBeliefs(fgl, r"x\d", sortVars=true, fade=minimum([15; nvars]), fadeFloor=0.2,
                              xmin=xmin,xmax=xmax,ymin=ymin,ymax=ymax,
                              resolution=(1920, 1080) )
    #
    Base.rm(joinLogPath(fg,"frames/$fname.png"), force=true)
    Makie.save(joinLogPath(fg,"frames/$fname.png"), pl)

    # draw lines
    addLinesBelief!(fgl, pl)
    Base.rm(joinLogPath(fg,"lines/$fname.png"), force=true)
    Makie.save(joinLogPath(fg,"lines/$fname.png"), pl)
  catch ex
    @error ex
  end
  GC.gc()
end

end





## Look at factor reports separately
if pargs["reportRanges"]
  reportFactors(fg, Pose2Point2Range, show=false)
end


if pargs["reportPoses"]
  reportFactors(fg, Pose2Pose2, show=false)
end








0



## Develop ranges alongside

if pargs["drawAllRanges"]

  mkpath(joinLogPath(fg, "ranges"))

  files = glob("fg_x*.tar.gz", getLogPath(fg))
  indiv = splitpath.(files) .|> x->x[end]

  # vsym = ls(fg, r"x\d") |> sortDFG

  PP2 = ls(fg, r"x\d")
  fcPP2R = ls(fg, Pose2Point2Range)

  # j=10
  for ind in indiv
    fname = split(ind, '.')[1]
    fgl = LightDFG{SolverParams}(params=SolverParams())
    loadDFG(joinLogPath(fg, ind), Main, fgl)
    vsym = ls(fgl, r"x\d") |> sortDFG
    filter!(x->isSolved(fgl, x), vsym)
    j = length(vsym)
    if j < 10
      continue
    end
  # for j in 10:length(vsym)
    for i in 1:10
      global latestPP2R = intersect(union(map(v->ls(fgl,v),vsym[j-i:j])...), fcPP2R)
      0 < length(latestPP2R) ? break : nothing
    end
    if length(latestPP2R) == 0
      continue
    end
    rangePose = intersect(ls(fgl, latestPP2R[1]), PP2)[1]
    hdl = []
    plotFactor(fgl, latestPP2R[1], hdl=hdl)
    hdl[4].coord = Coord.Cartesian(xmin=50, xmax=300)
    hdl[4] |> PNG(joinLogPath(fg, "ranges/$rangePose.png"))
  end

end

0

## Plot reference poses



#
# fg, dashboard = main(logSpeed=0.25, lcm=LCMLog(joinpath(ENV["HOME"],"data","sandshark","lcmlog","lcmlog-2019-11-26.01")) ) # bad ranges

# find . -type f -name '*.pdf' -print0 |
#   while IFS= read -r -d '' file
#     do convert -verbose -density 500 -quality 100 "${file}" "png/${file%.*}.png"
#   done

# ls nobytes/ | sed 's/bt_//g' | sed 's/.pdf//g' | xargs -L1
