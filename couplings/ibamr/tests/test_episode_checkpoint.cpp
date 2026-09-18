#include "EpisodeMailbox.h"
#include <mpi.h>
#include <iostream>
#include <stdexcept>
#include <unistd.h>
using namespace ibamr_smarties::eel2d;
int main(int argc,char** argv) {
  MPI_Init(&argc,&argv);
  int rank=0; MPI_Comm_rank(MPI_COMM_WORLD,&rank);
  int result=0;
  try {
    if (argc!=2) throw std::runtime_error("test needs private existing directory");
    const std::string directory=argv[1];
    FileEpisodeChannel channel(directory,MPI_COMM_WORLD);
    channel.restoreSequence(5);
    int saved=0;
    channel.setCheckpointHandler([&](const std::string& path) {
      if (path!=directory+"/save" || channel.sequence()!=5)
        throw std::runtime_error("wrong snapshot boundary");
      ++saved;
    });
    if (!rank) {
      publish(directory+"/checkpoint.request",directory+"/save");
      publish(directory+"/action","5 A 0.75");
    }
    MPI_Barrier(MPI_COMM_WORLD);
    if (channel.recvAction().at(0)!=0.75 || saved!=1)
      throw std::runtime_error("checkpoint lost pending action");
    if (channel.recvAction().at(0)!=0.75 || saved!=1)
      throw std::runtime_error("same checkpoint written twice");
    channel.sendState(std::vector<double>(25,0.1),2.5);
    MPI_Barrier(MPI_COMM_WORLD);
    const auto message=parseMessage(readMessage(directory+"/state"));
    if (message.sequence!=6 || message.kind!='S' || message.reward!=2.5)
      throw std::runtime_error("restored feedback duplicated or sequence reset");
    if (readMessage(directory+"/cfd.ready")!=directory+"/save\n")
      throw std::runtime_error("missing CFD acknowledgement");
    std::cout << "episode checkpoint passed\n";
  } catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; MPI_Abort(MPI_COMM_WORLD,1); }
  MPI_Finalize(); return result;
}
