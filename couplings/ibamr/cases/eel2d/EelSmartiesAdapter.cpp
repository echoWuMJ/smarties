#include "EelSmartiesAdapter.h"

#include "EelEnvironment.h"

#include <smarties.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <chrono>

namespace ibamr_smarties
{
namespace eel2d
{
namespace
{

SmokeProtocolReport protocol_report{ 0, false };

struct SmokeOptions
{
  std::string input_file = "input2d";
  unsigned smoke_steps = 1;
  bool fault_after_initialize = false;
};

[[noreturn]] void abortInvalidOption(MPI_Comm comm, const char* message)
{
  int rank = 0;
  MPI_Comm_rank(comm, &rank);
  if (rank == 0) std::fprintf(stderr, "eel2d smoke option error: %s\n", message);
  MPI_Abort(comm, 95);
  std::abort();
}

unsigned parsePositiveUnsigned(const char* text, MPI_Comm comm)
{
  if (text == nullptr || *text == '\0') abortInvalidOption(comm, "empty --smoke-steps");
  errno = 0;
  char* end = nullptr;
  const unsigned long value = std::strtoul(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value == 0 ||
      value > std::numeric_limits<unsigned>::max()) {
    abortInvalidOption(comm, "--smoke-steps must be a positive integer");
  }
  return static_cast<unsigned>(value);
}

SmokeOptions parseSmokeOptions(int argc, char** argv, MPI_Comm comm)
{
  SmokeOptions options;
  for (int i = 1; i < argc; ++i) {
    const std::string argument(argv[i]);
    if (argument == "--input-file") {
      if (++i >= argc) abortInvalidOption(comm, "missing value after --input-file");
      options.input_file = argv[i];
    }
    else if (argument == "--smoke-steps") {
      if (++i >= argc) abortInvalidOption(comm, "missing value after --smoke-steps");
      options.smoke_steps = parsePositiveUnsigned(argv[i], comm);
    }
    else if (argument == "--fault-after-initialize") {
      options.fault_after_initialize = true;
    }
  }
  if (options.input_file.empty()) abortInvalidOption(comm, "--input-file must not be empty");
  return options;
}

[[noreturn]] void abortEnvironmentFailure(MPI_Comm comm, const char* message)
{
  int rank = 0;
  MPI_Comm_rank(comm, &rank);
  if (rank == 0) {
    std::fprintf(stderr, "eel2d environment fatal error: %s\n", message);
    std::fflush(stderr);
  }
  MPI_Abort(comm, 98);
  std::abort();
}

} // namespace

void runSmokeEpisode(smarties::Communicator* const comm,
                     MPI_Comm environment_comm,
                     int argc,
                     char** argv)
{
  protocol_report = { 0, false };
  if (comm == nullptr || environment_comm == MPI_COMM_NULL) {
    MPI_Abort(MPI_COMM_WORLD, 96);
  }

  const SmokeOptions options = parseSmokeOptions(argc, argv, environment_comm);

  try {
    comm->setStateActionDims(1, 1);
    comm->setActionScales({ 1.0 }, { -1.0 }, true);

    EelEnvironment environment;
    environment.initialize(environment_comm, options.input_file);
    if (options.fault_after_initialize) {
      throw std::runtime_error("injected failure after IBAMR initialization");
    }
    comm->sendInitState({ 0.0 });

  for (unsigned step = 0;
       step < options.smoke_steps && environment.stepsRemaining();
       ++step) {
    const std::vector<double> action = comm->recvAction();
    if (action.size() != 1) MPI_Abort(environment_comm, 92);

    // Phase-one lifecycle probe: the action is shape-checked but intentionally
    // not applied to the fish. A physical control law is a later specification.
    environment.advanceOneStep();
    protocol_report.completed_steps = step + 1;
    const double normalized_time =
      static_cast<double>(step + 1) / options.smoke_steps;
    const bool terminal =
      step + 1 == options.smoke_steps || !environment.stepsRemaining();

    // Zero reward and normalized time test the protocol lifecycle only; they
    // are not an RL state/reward formulation.
    if (terminal) {
      comm->sendTermState({ normalized_time }, 0.0);
      protocol_report.terminal_sent = true;
      int environment_rank = 0;
      MPI_Comm_rank(environment_comm, &environment_rank);
      if (environment_rank == 0) {
        std::printf("EEL_SMOKE_TERMINAL steps=%u\n", step + 1);
        std::fflush(stdout);
      }
    }
    else {
      comm->sendState({ normalized_time }, 0.0);
    }

    if (comm->terminateTraining()) break;
  }

  if (protocol_report.terminal_sent) {
    // Smarties reports KILL on the next state/action exchange after its master
    // observes that the requested training step count has been reached. Start
    // no second IBAMR episode: poll with initial-state handshakes only.
    constexpr auto termination_timeout = std::chrono::seconds(30);
    const auto termination_deadline =
      std::chrono::steady_clock::now() + termination_timeout;
    while (std::chrono::steady_clock::now() < termination_deadline &&
           !comm->terminateTraining()) {
      comm->sendInitState({ 1.0 });
      if (!comm->terminateTraining()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    }
  }
  if (!protocol_report.terminal_sent || !comm->terminateTraining()) {
    int environment_rank = 0;
    MPI_Comm_rank(environment_comm, &environment_rank);
    if (environment_rank == 0) {
      std::fprintf(stderr,
                   "eel2d smoke protocol did not receive Smarties termination\n");
    }
    MPI_Abort(environment_comm, 97);
  }

    environment.shutdown();
  }
  catch (const std::exception& error) {
    abortEnvironmentFailure(environment_comm, error.what());
  }
  catch (...) {
    abortEnvironmentFailure(environment_comm, "unknown exception");
  }
}

SmokeProtocolReport lastSmokeProtocolReport()
{
  return protocol_report;
}

} // namespace eel2d
} // namespace ibamr_smarties
