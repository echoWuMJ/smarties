#ifndef IBAMR_SMARTIES_COUPLING_DRIVER_H
#define IBAMR_SMARTIES_COUPLING_DRIVER_H

#include "MpiSession.h"

#include <smarties.h>

#include <functional>

namespace ibamr_smarties
{

using EnvironmentCallback = std::function<void(
  smarties::Communicator* const, MPI_Comm, int, char**)>;

class CouplingDriver
{
public:
  CouplingDriver(int& argc, char**& argv);

  CouplingDriver(const CouplingDriver&) = delete;
  CouplingDriver& operator=(const CouplingDriver&) = delete;

  int run(const EnvironmentCallback& callback);

private:
  MpiSession mpi_;
  int argc_;
  char** argv_;
};

} // namespace ibamr_smarties

#endif
