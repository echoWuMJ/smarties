#include "CouplingDriver.h"

#include <smarties.h>

#include <mpi.h>

#include <cstdio>
#include <stdexcept>
#include <vector>

namespace
{
void runDistributedEnvironment(smarties::Communicator* const comm,
                               const MPI_Comm environment_comm)
{
  int environment_rank = 0;
  int environment_size = 0;
  MPI_Comm_rank(environment_comm, &environment_rank);
  MPI_Comm_size(environment_comm, &environment_size);
  if (environment_size < 2)
    throw std::runtime_error(
      "shutdown probe requires a distributed environment");

  comm->envHasDistributedAgents();
  comm->setStateActionDims(1, 1);
  comm->setActionScales({ 1.0 }, { -1.0 }, true);

  unsigned episodes = 0;
  while (!comm->terminateTraining() && episodes < 64)
  {
    comm->sendInitState({ static_cast<double>(episodes) });
    if (comm->terminateTraining()) break;

    const std::vector<double> action = comm->recvAction();
    if (action.size() != 1)
      throw std::runtime_error("shutdown probe received an invalid action");

    comm->sendTermState({ static_cast<double>(episodes + 1) }, 0.0);
    ++episodes;
  }

  if (!comm->terminateTraining())
    throw std::runtime_error("shutdown probe exhausted its episode bound");
  if (environment_rank == 0)
  {
    std::printf("DISTRIBUTED_ENVIRONMENT_CALLBACK_RETURNED ranks=%d episodes=%u\n",
                environment_size, episodes);
    std::fflush(stdout);
  }
}
} // namespace

int main(int argc, char** argv)
{
  int result = 0;
  int finalized = 0;
  {
    ibamr_smarties::CouplingDriver driver(argc, argv);
    const auto callback = [](
      smarties::Communicator* const comm,
      const MPI_Comm environment_comm,
      int, char**) {
      runDistributedEnvironment(comm, environment_comm);
    };
    result = driver.run(callback);
    if (result != 0) return result;

    MPI_Finalized(&finalized);
    if (finalized != 0) return 93;
    int world_rank = 0;
    MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);
    if (world_rank == 0)
      std::puts("COUPLING_DRIVER_RETURNED_MPI_ACTIVE");
  }

  MPI_Finalized(&finalized);
  if (finalized == 0) return 94;
  std::puts("COUPLING_DRIVER_DESTROYED_MPI_FINALIZED");
  return result;
}
