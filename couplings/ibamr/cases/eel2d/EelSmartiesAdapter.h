#ifndef IBAMR_SMARTIES_EEL_SMARTIES_ADAPTER_H
#define IBAMR_SMARTIES_EEL_SMARTIES_ADAPTER_H

#include <mpi.h>

namespace smarties
{
class Communicator;
}

namespace ibamr_smarties
{
namespace eel2d
{

struct SmokeProtocolReport
{
  unsigned completed_steps;
  bool terminal_sent;
};

void runSmokeEpisode(smarties::Communicator* const comm,
                     MPI_Comm environment_comm,
                     int argc,
                     char** argv);

SmokeProtocolReport lastSmokeProtocolReport();

} // namespace eel2d
} // namespace ibamr_smarties

#endif
