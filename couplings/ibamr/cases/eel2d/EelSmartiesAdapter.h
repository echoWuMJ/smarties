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

enum class EelMode
{
  smoke,
  near_wall,
  speed_tracking
};

EelMode parseEelMode(int argc, char** argv);
void runNearWallEpisodes(smarties::Communicator*, MPI_Comm, int, char**);

struct SmokeProtocolReport
{
  unsigned completed_steps;
  bool terminal_sent;
};

struct ControlProtocolReport
{
  unsigned completed_segments;
  unsigned completed_decisions;
  unsigned completed_ibamr_steps;
  unsigned clipped_actions;
  unsigned truncated_segments;
  unsigned environment_initializations;
  bool smarties_termination_received;
  bool finite_state_and_reward;
  unsigned state_dimension;
  unsigned action_dimension;
};

void runSmokeEpisode(smarties::Communicator* const comm,
                     MPI_Comm environment_comm,
                     int argc,
                     char** argv);

void runSpeedTrackingEpisode(smarties::Communicator* const comm,
                             MPI_Comm environment_comm,
                             int argc,
                             char** argv);

SmokeProtocolReport lastSmokeProtocolReport();
ControlProtocolReport lastControlProtocolReport();

} // namespace eel2d
} // namespace ibamr_smarties

#endif
