#include "EelSmartiesAdapter.h"
#include "EelEnvironment.h"
#include "EelNearWallTask.h"
#include "EelControlTask.h"
#include "EpisodeMailbox.h"
#include "MpiSession.h"
#include <ibtk/IBTKInit.h>
#include <tbox/SAMRAI_MPI.h>
#include <petscsys.h>
#include <unistd.h>
#include <sys/stat.h>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <random>
#include <memory>
#include <omp.h>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace ibamr_smarties { namespace eel2d {
namespace {
struct AbortDuringUnwind
{
  MPI_Comm communicator;
  ~AbortDuringUnwind() {
    if (std::uncaught_exception()) MPI_Abort(communicator,98);
  }
};
std::string readFile(const std::string& path)
{
  std::ifstream in(path);
  if (!in) throw std::runtime_error("cannot read " + path);
  return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}
void writeFile(const std::string& path, const std::string& data)
{
  std::ofstream out(path);
  out << data;
  if (!out) throw std::runtime_error("cannot write " + path);
}
void replaceSetting(std::string& text, const std::string& key, const std::string& value)
{
  std::istringstream in(text);
  std::ostringstream out;
  std::string line;
  unsigned matches=0;
  while (std::getline(in,line)) {
    const auto first = line.find_first_not_of(" \t");
    if (first != std::string::npos && line.compare(first,key.size(),key)==0 &&
        line.find('=',first+key.size()) != std::string::npos) {
      line = "   " + key + " = " + value;
      ++matches;
    }
    out << line << '\n';
  }
  if (matches != 1) throw std::runtime_error("expected one input setting: " + key);
  text=out.str();
}
std::vector<double> vectorState(const NearWallState& s) { return {s.begin(),s.end()}; }
}

void runStandaloneEpisode(FileEpisodeChannel* comm, MPI_Comm env_comm,
                         int argc, char** argv)
{
  int rank=0, world_rank=0;
  MPI_Comm_rank(env_comm,&rank);
  MPI_Comm_rank(MPI_COMM_WORLD,&world_rank);
  std::unique_ptr<IBTK::IBTKInit> runtime;
  try {
    omp_set_num_threads(1);
    NearWallConfig config;
    std::string input="input2d", task_file;
    unsigned seed=20260908;
    for (int i=1;i<argc;++i) {
      const std::string arg=argv[i];
      if (arg=="--input-file" || arg=="--task-file" || arg=="--wall-seed" ||
          arg=="--wall-max-periods" || arg=="--wall-target-distance") {
        if (++i>=argc) throw std::invalid_argument("missing value for " + arg);
        if (arg=="--input-file") input=argv[i];
        else if (arg=="--task-file") task_file=argv[i];
        else if (arg=="--wall-seed") seed=static_cast<unsigned>(std::stoul(argv[i]));
        else if (arg=="--wall-max-periods") config.maximum_periods=std::stod(argv[i]);
        else config.target_distance=std::stod(argv[i]);
      }
    }
    config.validate();
    const EelTaskConfig action_config=loadEelTaskConfig(task_file);
    if (std::abs(EelControlTask(action_config).controlInterval()-config.controlInterval())>1e-12)
      throw std::invalid_argument("near-wall action cadence must be eight decisions per baseline period");
    char cwd[4096];
    if (!getcwd(cwd,sizeof(cwd))) throw std::runtime_error("getcwd failed");
    const std::string root=cwd;
    const std::string original_input=readFile(input);
    const std::string vertices=readFile("eel2d.vertex");
    int root_world_rank=world_rank;
    MPI_Bcast(&root_world_rank,1,MPI_INT,0,env_comm);
    std::seed_seq sequence{seed,static_cast<unsigned>(root_world_rank)};
    std::mt19937 rng(sequence);
    std::uniform_real_distribution<double> heights(config.initial_height_min*config.length,
                                                    config.initial_height_max*config.length);

    PETSC_COMM_WORLD=env_comm;
    // Runtime lives for this single CFD job and is destroyed before its MPI owner.
    runtime.reset(new IBTK::IBTKInit(argc,argv,env_comm));
    SAMRAI::tbox::SAMRAI_MPI::setCommunicator(env_comm);
    unsigned episode=0, decisions=0;
    while (!comm->terminateTraining()) {
      ++episode;
      double height=rank==0?heights(rng):0;
      MPI_Bcast(&height,1,MPI_DOUBLE,0,env_comm);
      std::ostringstream name;
      name << root << "/cfd";
      const std::string directory=name.str();
      if (rank==0) {
        if (mkdir(directory.c_str(),0755)!=0)
          throw std::runtime_error("cannot create new episode directory: " + directory);
        std::string episode_input=original_input;
        // Only the first physical episode retains field visualization.
        replaceSetting(episode_input,"viz_dump_interval",std::getenv("EEL_KEEP_VIZ")?"2000":"0");
        replaceSetting(episode_input,"restart_dump_interval","0");
        replaceSetting(episode_input,"output_interval","100");
        replaceSetting(episode_input,"END_TIME",std::to_string(config.maximum_periods*config.period));
        writeFile(directory+"/input2d",episode_input);
        writeFile(directory+"/eel2d.vertex",vertices);
        std::ostringstream info;
        info << std::setprecision(17) << "episode=" << episode << "\nseed=" << seed
             << "\nenvironment_root_world_rank=" << root_world_rank
             << "\ninitial_height=" << height << "\n";
        writeFile(directory+"/episode.conf",info.str());
      }
      MPI_Barrier(env_comm);
      if (chdir(directory.c_str())!=0) throw std::runtime_error("cannot enter episode directory");
      {
        EelEnvironment environment;
        AbortDuringUnwind abort_before_environment_destructor{env_comm};
        EelControlTask control(action_config);
        environment.initializeNearWall(env_comm,"input2d",config,height);
        NearWallObservation o=environment.nearWallObservation();
        auto probes=environment.sampleVelocityProbes();
        o.fluid_velocity=probes.velocities;
        NearWallState state=makeNearWallState(o,config);
        std::ofstream trace;
        if (rank==0) {
          trace.open("transitions.csv");
          trace << "episode,decision,time,height,min_gap,progress,vx,vy,angle,angular_velocity,ratio,fx,mean_ct,reward,end";
          for (unsigned p=0;p<EEL_PROBE_COUNT;++p)
            trace << ",p" << p << "_x,p" << p << "_y,p" << p << "_u,p" << p << "_v";
          trace << ",flow_sample_current\n";
          std::printf("EEL_NEAR_WALL_INIT episode=%u time=%.17g height=%.17g points=%zu directory=%s\n",
                      episode,o.time,o.height,environment.globalLagrangianPointCount(),directory.c_str());
          std::fflush(stdout);
        }
        comm->sendInitState(vectorState(state));
        NearWallEnd end=NearWallEnd::running;
        while (!comm->terminateTraining() && end==NearWallEnd::running) {
          auto action=comm->recvAction();
          if (comm->terminateTraining()) break;
          if (action.size()!=1) throw std::runtime_error("near-wall action must be scalar");
          auto decision=control.applyAction(action[0]);
          environment.setTailBeatFrequencyRatio(decision.applied_ratio);
          const double start=environment.currentTime();
          double impulse=0;
          while (environment.stepsRemaining() && environment.currentTime()-start<config.controlInterval()) {
            const double before=environment.currentTime();
            environment.advanceOneStep();
            impulse+=environment.currentForceX()*(environment.currentTime()-before);
            o=environment.nearWallObservation();
            end=nearWallEnd(o,config);
            if (end!=NearWallEnd::running) break;
          }
          if (!environment.stepsRemaining() && end==NearWallEnd::running) end=NearWallEnd::time_limit;
          o.previous_frequency_ratio=decision.previous_ratio;
          // Terminal geometry can lie outside the sampling domain. A true
          // terminal does not bootstrap; preserve the last finite flow sample.
          if (!nearWallIsTerminal(end)) probes=environment.sampleVelocityProbes();
          o.fluid_velocity=probes.velocities;
          state=makeNearWallState(o,config);
          const double reward=nearWallReward(impulse,end,config);
          ++decisions;
          if (rank==0) {
            trace << std::setprecision(17) << episode << ',' << decisions << ',' << o.time << ','
                  << o.height << ',' << o.minimum_gap << ',' << o.progress << ','
                  << o.velocity[0] << ',' << o.velocity[1] << ',' << o.body_angle << ','
                  << o.angular_velocity << ',' << o.frequency_ratio << ',' << environment.currentForceX()
                  << ',' << nearWallForceCoefficient(impulse,config)/config.controlInterval()
                  << ',' << reward << ',' << nearWallEndName(end);
            for (unsigned p=0;p<EEL_PROBE_COUNT;++p)
              trace << ',' << probes.positions[p][0] << ',' << probes.positions[p][1]
                    << ',' << probes.velocities[p][0] << ',' << probes.velocities[p][1];
            trace << ',' << (!nearWallIsTerminal(end)) << '\n';
            trace.flush();
            if (!trace) throw std::runtime_error("cannot write near-wall transition log");
            std::printf("EEL_NEAR_WALL episode=%u decision=%u t=%.8g h=%.8g reward=%.8g end=%s\n",
                        episode,decisions,o.time,o.height,reward,nearWallEndName(end));
            std::fflush(stdout);
          }
          if (end==NearWallEnd::running) comm->sendState(vectorState(state),reward);
          else if (nearWallIsTerminal(end)) comm->sendTermState(vectorState(state),reward);
          else comm->sendLastState(vectorState(state),reward);
        }
        environment.writeVisualizationSnapshot();
        environment.shutdown();
      }
      // One physical episode per operating-system process; no singleton reset.
      if (chdir(root.c_str())!=0) throw std::runtime_error("cannot leave episode directory");
      break; // The launcher starts a fresh MPI job for the next physical episode.
    }
    if (rank==0) { std::printf("EEL_NEAR_WALL_COMPLETE episodes=%u decisions=%u\n",episode,decisions); std::fflush(stdout); }
    runtime.reset();
  } catch (const std::exception& error) {
    if (rank==0) { std::fprintf(stderr,"near-wall environment fatal: %s\n",error.what()); std::fflush(stderr); }
    MPI_Abort(env_comm,98);
  }
}
} }

int main(int argc,char** argv) {
  ibamr_smarties::MpiSession mpi(argc,argv);
  char cwd[4096];
  if (!getcwd(cwd,sizeof(cwd))) { MPI_Abort(mpi.world(),98); return 98; }
  ibamr_smarties::eel2d::FileEpisodeChannel channel(cwd,mpi.world());
  ibamr_smarties::eel2d::runStandaloneEpisode(&channel,mpi.world(),argc,argv);
  return 0;
}
