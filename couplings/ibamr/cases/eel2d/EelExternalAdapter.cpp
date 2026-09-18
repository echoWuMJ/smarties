#include "EelSmartiesAdapter.h"
#include "EpisodeMailbox.h"
#include "PairedEpisodeState.h"
#include <smarties.h>
#include <cstdlib>

namespace ibamr_smarties { namespace eel2d {
namespace {
void actionMessage(const std::string& dir,unsigned sequence,double action,bool stop=false) {
  std::ostringstream out;
  out<<std::setprecision(17)<<sequence<<' '<<(stop?'X':'A')<<' '<<(stop?0:action);
  publish(dir+"/action",out.str());
}
void awaitExit(const std::string& dir) {
  std::string status;
  while ((status=readMessage(dir+"/exit.status")).empty()) usleep(10000);
  if (std::stoi(status)!=0) throw std::runtime_error("CFD episode failed: "+status);
}
bool pauseIfRequested(smarties::Communicator* comm,const std::string& slot,
                      const ProxyRestart& state,std::string& last_checkpoint) {
  const std::string destination=readPathMessage(slot+"/checkpoint.request");
  if (destination.empty() || destination==last_checkpoint) return false;
  comm->saveAgentState(destination+"/agent.state");
  publish(destination+"/proxy.state",serializeProxyRestart(state));
  publish(slot+"/proxy.ready",destination);
  for (;;) {
    std::istringstream in(readMessage(slot+"/checkpoint.release"));
    std::string path,command; std::getline(in,path); std::getline(in,command);
    if (path==destination) {
      if (command!="CONTINUE" && command!="STOP") throw std::runtime_error("invalid checkpoint release");
      last_checkpoint=destination;
      return command=="STOP";
    }
    usleep(10000);
  }
}
}
void runNearWallEpisodes(smarties::Communicator* comm,MPI_Comm env_comm,int,char**) {
  try {
    int size=0,world_rank=0;
    MPI_Comm_size(env_comm,&size); MPI_Comm_rank(MPI_COMM_WORLD,&world_rank);
    if (size!=1) throw std::runtime_error("external mode requires one proxy rank per environment");
    const char* base=std::getenv("EEL_EXTERNAL_ROOT");
    if (!base) throw std::runtime_error("start external mode through external_episode_manager.py");
    const std::string slot=std::string(base)+"/env_"+std::to_string(world_rank);
    comm->setStateActionDims(25,1); comm->setActionScales({1.0},{-1.0},true);
    comm->finalizeProblemDescription();
    unsigned first_episode=1;
    ProxyRestart restored;
    const char* restore=std::getenv("EEL_PAIRED_RESTORE");
    bool resume_active=false;
    if (restore) {
      const std::string source=std::string(restore)+"/env_"+std::to_string(world_rank);
      restored=parseProxyRestart(readMessage(source+"/proxy.state"));
      comm->restoreAgentState(source+"/agent.state");
      first_episode=restored.episode; resume_active=restored.kind=='A';
      if (resume_active) publish(slot+"/request",std::to_string(first_episode));
      publish(slot+"/resume.ready",source);
      while (readPathMessage(std::string(base)+"/resume.release")!=restore) usleep(10000);
    }
    std::string last_checkpoint;
    for (unsigned episode=first_episode; !comm->terminateTraining(); ++episode) {
      const std::string dir=slot+"/episode_"+std::to_string(episode);
      unsigned expected=1;
      if (resume_active) {
        actionMessage(dir,restored.sequence,restored.action);
        expected=restored.sequence+1; resume_active=false;
      } else {
        if (pauseIfRequested(comm,slot,{episode,0,'N',0},last_checkpoint)) return;
        publish(slot+"/request",std::to_string(episode));
      }
      bool complete=false;
      while (!complete) {
        // A request can cross the supervisor's "stop launching" decision.
        // It explicitly acknowledges that this episode has NOT been launched;
        // the proxy can then save a next-episode slot without waiting for INIT.
        if (expected==1 && readPathMessage(slot+"/park.next")==std::to_string(episode))
          if (pauseIfRequested(comm,slot,{episode,0,'N',0},last_checkpoint)) return;
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
              bool stop=comm->terminateTraining();
              if (!stop && (a.size()!=1 || !std::isfinite(a[0]))) throw std::runtime_error("invalid learner action");
              const bool saved_stop=!stop && pauseIfRequested(comm,slot,{episode,expected,'A',a[0]},last_checkpoint);
              stop=stop||saved_stop;
              actionMessage(dir,expected,stop?0:a[0],stop);
              if (saved_stop) { awaitExit(dir); return; }
              complete=stop;
            }
            ++expected;
            continue;
          }
        }
        if (!status.empty()) throw std::runtime_error("CFD exited before complete transition: "+status);
        usleep(10000);
      }
      awaitExit(dir);
      std::printf("EXTERNAL_EPISODE_COMPLETE env=%d episode=%u\n",world_rank,episode); std::fflush(stdout);
    }
  } catch (const std::exception& e) {
    std::fprintf(stderr,"external adapter fatal: %s\n",e.what()); std::fflush(stderr);
    MPI_Abort(MPI_COMM_WORLD,98);
  }
}
} }
