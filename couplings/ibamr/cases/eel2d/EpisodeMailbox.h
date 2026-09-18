#pragma once
#include <mpi.h>
#include <unistd.h>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <functional>
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
inline std::string readPathMessage(const std::string& path) {
  std::istringstream in(readMessage(path)); std::string value, extra;
  std::getline(in,value);
  if (!value.empty() && value.back()=='\r') value.pop_back();
  if (std::getline(in,extra) && !extra.empty()) throw std::runtime_error("invalid path message");
  return value;
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
  std::function<void(const std::string&)> checkpoint_handler_;
  std::string last_checkpoint_;
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
  unsigned sequence() const { return sequence_; }
  void restoreSequence(unsigned value) {
    if (sequence_ || !value) throw std::logic_error("invalid episode restore sequence");
    sequence_=value;
  }
  void setCheckpointHandler(std::function<void(const std::string&)> handler) {
    checkpoint_handler_=std::move(handler);
  }
  void sendInitState(const std::vector<double>& s) { send('I',s,0); }
  void sendState(const std::vector<double>& s,double r) { send('S',s,r); }
  void sendTermState(const std::vector<double>& s,double r) { send('T',s,r); }
  void sendLastState(const std::vector<double>& s,double r) { send('L',s,r); }
  std::vector<double> recvAction() {
    double action=0; int stop=0;
    for (;;) {
      int operation=0;
      std::string destination;
      if (!rank_) for (;;) {
        if (access((root_+"/cancel").c_str(),F_OK)==0) { stop=1; operation=1; break; }
        destination=readPathMessage(root_+"/checkpoint.request");
        if (!destination.empty() && destination!=last_checkpoint_) { operation=2; break; }
        std::istringstream in(readMessage(root_+"/action")); unsigned seq=0; char kind=0;
        if (in>>seq>>kind>>action) {
          if (seq>sequence_) throw std::runtime_error("future action sequence");
          if (seq==sequence_) {
            if ((kind!='A' && kind!='X') || !std::isfinite(action)) throw std::runtime_error("invalid action");
            stop=kind=='X'; operation=1; break;
          }
        }
        usleep(10000);
      }
      MPI_Bcast(&operation,1,MPI_INT,0,mpi_);
      if (operation==1) break;
      if (operation!=2 || !checkpoint_handler_) throw std::runtime_error("CFD checkpoint handler unavailable");
      unsigned length=destination.size();
      MPI_Bcast(&length,1,MPI_UNSIGNED,0,mpi_);
      if (!length || length>4096) throw std::runtime_error("invalid CFD checkpoint destination length");
      destination.resize(length);
      MPI_Bcast(&destination[0],length,MPI_CHAR,0,mpi_);
      checkpoint_handler_(destination); // All CFD ranks enter native restart I/O.
      MPI_Barrier(mpi_);
      if (!rank_) publish(root_+"/cfd.ready",destination);
      last_checkpoint_=destination;
    }
    MPI_Bcast(&stop,1,MPI_INT,0,mpi_); MPI_Bcast(&action,1,MPI_DOUBLE,0,mpi_);
    stopped_=stop; return {action};
  }
};
} }
