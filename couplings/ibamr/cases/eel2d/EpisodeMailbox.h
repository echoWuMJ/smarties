#pragma once
#include <mpi.h>
#include <unistd.h>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace ibamr_smarties { namespace eel2d {
inline void publish(const std::string& path, const std::string& message) {
  const std::string temporary=path+".tmp";
  { std::ofstream out(temporary); out << message << '\n'; out.close();
    if (!out) throw std::runtime_error("cannot publish " + path); }
  if (std::rename(temporary.c_str(),path.c_str())) throw std::runtime_error("cannot rename " + path);
}
inline std::string readMessage(const std::string& path) {
  std::ifstream in(path);
  return {std::istreambuf_iterator<char>(in),std::istreambuf_iterator<char>()};
}
// Single writer per mailbox; sequence numbers distinguish an old atomic file
// from the next transition. No CFD field data is transmitted here.
struct EpisodeMessage {
  unsigned sequence=0; char kind=0; double reward=0; std::vector<double> state;
};
inline EpisodeMessage parseMessage(const std::string& text) {
  EpisodeMessage m; std::istringstream in(text); unsigned size=0;
  if (!(in>>m.sequence>>m.kind>>m.reward>>size) || size!=25 || !std::isfinite(m.reward))
    throw std::runtime_error("invalid episode state header");
  m.state.resize(size);
  for (double& x:m.state) if (!(in>>x) || !std::isfinite(x)) throw std::runtime_error("invalid observation");
  std::string extra;
  if (in>>extra) throw std::runtime_error("extra state fields");
  if (m.kind!='I' && m.kind!='S' && m.kind!='T' && m.kind!='L') throw std::runtime_error("invalid state type");
  return m;
}
class FileEpisodeChannel {
  std::string root_; MPI_Comm mpi_; int rank_=0; unsigned sequence_=0; bool stopped_=false;
  void send(char kind,const std::vector<double>& state,double reward) {
    ++sequence_;
    if (!rank_) {
      std::ostringstream out; out<<std::setprecision(17)<<sequence_<<' '<<kind<<' '<<reward<<' '<<state.size();
      for (double x:state) out<<' '<<x;
      publish(root_+"/state",out.str());
    }
  }
public:
  FileEpisodeChannel(std::string root,MPI_Comm mpi):root_(std::move(root)),mpi_(mpi) { MPI_Comm_rank(mpi_,&rank_); }
  bool terminateTraining() const { return stopped_; }
  void sendInitState(const std::vector<double>& s) { send('I',s,0); }
  void sendState(const std::vector<double>& s,double r) { send('S',s,r); }
  void sendTermState(const std::vector<double>& s,double r) { send('T',s,r); }
  void sendLastState(const std::vector<double>& s,double r) { send('L',s,r); }
  std::vector<double> recvAction() {
    double action=0; int stop=0;
    if (!rank_) for (;;) {
      if (access((root_+"/cancel").c_str(),F_OK)==0) { stop=1; break; }
      std::istringstream in(readMessage(root_+"/action")); unsigned seq=0; char kind=0;
      if (in>>seq>>kind>>action) {
        if (seq>sequence_) throw std::runtime_error("future action sequence");
        if (seq==sequence_) {
          if ((kind!='A' && kind!='X') || !std::isfinite(action)) throw std::runtime_error("invalid action");
          stop=kind=='X'; break;
        }
      }
      usleep(10000);
    }
    MPI_Bcast(&stop,1,MPI_INT,0,mpi_); MPI_Bcast(&action,1,MPI_DOUBLE,0,mpi_);
    stopped_=stop; return {action};
  }
};
} }
