#include "EelSmartiesAdapter.h"
#include "EpisodeMailbox.h"
#include <smarties.h>
#include <cstdlib>

namespace ibamr_smarties { namespace eel2d {
void runNearWallEpisodes(smarties::Communicator* comm,MPI_Comm env_comm,int,char**) {
  try {
    int size=0,world_rank=0;
    MPI_Comm_size(env_comm,&size); MPI_Comm_rank(MPI_COMM_WORLD,&world_rank);
    if (size!=1) throw std::runtime_error("external mode requires one proxy rank per environment");
    const char* base=std::getenv("EEL_EXTERNAL_ROOT");
    if (!base) throw std::runtime_error("start external mode through external_episode_manager.py");
    const std::string slot=std::string(base)+"/env_"+std::to_string(world_rank);
    comm->setStateActionDims(25,1); comm->setActionScales({1.0},{-1.0},true);
    for (unsigned episode=1; !comm->terminateTraining(); ++episode) {
      const std::string dir=slot+"/episode_"+std::to_string(episode);
      publish(slot+"/request",std::to_string(episode));
      unsigned expected=1;
      bool complete=false;
      while (!complete) {
        // The supervisor publishes exit.status only after the CFD job exits.
        // Read it BEFORE state: otherwise a final state published between the
        // two reads could be mistaken for an exit without a final transition.
        const std::string status=readMessage(dir+"/exit.status");
        const std::string raw=readMessage(dir+"/state");
        if (!raw.empty()) {
          const auto m=parseMessage(raw);
          if (m.sequence>expected) throw std::runtime_error("skipped CFD transition");
          if (m.sequence==expected) {
            if ((expected==1)!=(m.kind=='I')) throw std::runtime_error("invalid initial state ordering");
            if (m.kind=='I') comm->sendInitState(m.state);
            else if (m.kind=='S') comm->sendState(m.state,m.reward);
            else if (m.kind=='T') comm->sendTermState(m.state,m.reward);
            else comm->sendLastState(m.state,m.reward);
            complete=m.kind=='T'||m.kind=='L';
            if (!complete) {
              std::vector<double> a;
              if (!comm->terminateTraining()) a=comm->recvAction();
              const bool stop=comm->terminateTraining();
              if (!stop && (a.size()!=1 || !std::isfinite(a[0]))) throw std::runtime_error("invalid learner action");
              std::ostringstream out; out<<std::setprecision(17)<<expected<<' '<<(stop?'X':'A')<<' '<<(stop?0:a[0]);
              publish(dir+"/action",out.str());
              complete=stop;
            }
            ++expected;
            continue;
          }
        }
        if (!status.empty()) throw std::runtime_error("CFD exited before complete transition: "+status);
        usleep(10000);
      }
      std::string status;
      while ((status=readMessage(dir+"/exit.status")).empty()) usleep(10000);
      if (std::stoi(status)!=0) throw std::runtime_error("CFD episode failed: "+status);
      std::printf("EXTERNAL_EPISODE_COMPLETE env=%d episode=%u\n",world_rank,episode); std::fflush(stdout);
    }
  } catch (const std::exception& e) {
    std::fprintf(stderr,"external adapter fatal: %s\n",e.what()); std::fflush(stderr);
    MPI_Abort(MPI_COMM_WORLD,98);
  }
}
} }
