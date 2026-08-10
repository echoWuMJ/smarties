#include "CouplingDriver.h"
#include "EelSmartiesAdapter.h"

#include <mpi.h>

#include <cstdio>
#include <stdexcept>

namespace
{
template <class Exception, class Function>
bool throws(Function function)
{
  try {
    function();
  }
  catch (const Exception&) {
    return true;
  }
  catch (...) {
  }
  return false;
}
} // namespace

int main(int argc, char** argv)
{
  using ibamr_smarties::eel2d::EelMode;
  using ibamr_smarties::eel2d::parseEelMode;

  char application[] = "eel";
  char invalid_option[] = "--eel-mode";
  char invalid_value[] = "unknown";
  char missing_option[] = "--eel-mode";
  char* default_arguments[] = { application };
  char* invalid_arguments[] = { application, invalid_option, invalid_value };
  char* missing_arguments[] = { application, missing_option };
  if (parseEelMode(1, default_arguments) != EelMode::smoke) return 90;
  if (parseEelMode(argc, argv) != EelMode::speed_tracking) return 91;
  if (!throws<std::invalid_argument>(
        [&] { parseEelMode(3, invalid_arguments); })) return 92;
  if (!throws<std::invalid_argument>(
        [&] { parseEelMode(2, missing_arguments); })) return 96;

  int finalized = 0;
  {
    ibamr_smarties::CouplingDriver driver(argc, argv);
    const int status =
      driver.run(ibamr_smarties::eel2d::runSpeedTrackingEpisode);
    if (status != 0) return status;

    const auto report =
      ibamr_smarties::eel2d::lastControlProtocolReport();
    const int local_terminal = report.terminal_sent ? 1 : 0;
    const int local_valid =
      report.terminal_sent && report.completed_decisions > 1 &&
      report.completed_ibamr_steps >= report.completed_decisions &&
      report.finite_state_and_reward && report.state_dimension == 5 &&
      report.action_dimension == 1 ? 1 : 0;
    int terminal_count = 0;
    int valid_count = 0;
    MPI_Allreduce(&local_terminal, &terminal_count, 1, MPI_INT, MPI_SUM,
                  MPI_COMM_WORLD);
    MPI_Allreduce(&local_valid, &valid_count, 1, MPI_INT, MPI_SUM,
                  MPI_COMM_WORLD);
    if (terminal_count != 1 || valid_count != 1) return 95;

    MPI_Finalized(&finalized);
    if (finalized != 0) return 93;
    std::puts("EEL_CONTROL_DRIVER_RETURNED_MPI_ACTIVE");
  }

  MPI_Finalized(&finalized);
  if (finalized == 0) return 94;
  std::puts("EEL_CONTROL_DRIVER_DESTROYED_MPI_FINALIZED");
  return 0;
}
