#include "EelSmartiesAdapter.h"

#include "EelControlMeasurement.h"
#include "EelControlTask.h"
#include "EelEnvironment.h"

#include <smarties.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace ibamr_smarties
{
namespace eel2d
{
namespace
{

SmokeProtocolReport protocol_report{ 0, false };
ControlProtocolReport control_protocol_report{ 0, 0, 0, false, false, 0, 0 };

struct SmokeOptions
{
  std::string input_file = "input2d";
  unsigned smoke_steps = 1;
  bool fault_after_initialize = false;
};

struct ControlOptions
{
  std::string input_file = "input2d";
  std::string task_file;
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

ControlOptions parseControlOptions(int argc, char** argv, MPI_Comm comm)
{
  ControlOptions options;
  for (int i = 1; i < argc; ++i) {
    const std::string argument(argv[i]);
    if (argument == "--input-file") {
      if (++i >= argc) abortInvalidOption(comm, "missing value after --input-file");
      options.input_file = argv[i];
    }
    else if (argument == "--task-file") {
      if (++i >= argc) abortInvalidOption(comm, "missing value after --task-file");
      options.task_file = argv[i];
    }
    else if (argument == "--fault-after-initialize") {
      options.fault_after_initialize = true;
    }
  }
  if (options.input_file.empty()) abortInvalidOption(comm, "--input-file must not be empty");
  if (options.task_file.empty()) abortInvalidOption(comm, "--task-file is required");
  return options;
}

std::vector<double> asVector(const std::array<double, 5>& state)
{
  return std::vector<double>(state.begin(), state.end());
}

bool finiteTransition(const std::array<double, 5>& state,
                      const RewardBreakdown& reward)
{
  for (const double value : state) {
    if (!std::isfinite(value)) return false;
  }
  return std::isfinite(reward.tracking) && std::isfinite(reward.frequency) &&
         std::isfinite(reward.smoothness) && std::isfinite(reward.total);
}

void awaitTrainingTermination(smarties::Communicator* const comm,
                              const std::vector<double>& state,
                              MPI_Comm environment_comm,
                              const char* protocol_name)
{
  constexpr auto termination_timeout = std::chrono::seconds(30);
  const auto termination_deadline =
    std::chrono::steady_clock::now() + termination_timeout;
  while (std::chrono::steady_clock::now() < termination_deadline &&
         !comm->terminateTraining()) {
    comm->sendInitState(state);
    if (!comm->terminateTraining()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
  if (!comm->terminateTraining()) {
    int environment_rank = 0;
    MPI_Comm_rank(environment_comm, &environment_rank);
    if (environment_rank == 0) {
      std::fprintf(stderr,
                   "eel2d %s protocol did not receive Smarties termination\n",
                   protocol_name);
    }
    MPI_Abort(environment_comm, 97);
  }
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

EelMode parseEelMode(const int argc, char** const argv)
{
  EelMode mode = EelMode::smoke;
  bool found_mode = false;
  for (int i = 1; i < argc; ++i) {
    if (std::string(argv[i]) != "--eel-mode") continue;
    if (found_mode)
      throw std::invalid_argument("--eel-mode may be specified only once");
    if (++i >= argc)
      throw std::invalid_argument("missing value after --eel-mode");
    const std::string value(argv[i]);
    if (value == "smoke") mode = EelMode::smoke;
    else if (value == "speed-tracking") mode = EelMode::speed_tracking;
    else
      throw std::invalid_argument(
        "--eel-mode must be smoke or speed-tracking");
    found_mode = true;
  }
  return mode;
}

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
    awaitTrainingTermination(comm, { 1.0 }, environment_comm, "smoke");
  }
  if (!protocol_report.terminal_sent) {
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

void runSpeedTrackingEpisode(smarties::Communicator* const comm,
                             MPI_Comm environment_comm,
                             int argc,
                             char** argv)
{
  control_protocol_report = { 0, 0, 0, false, true, 5, 1 };
  if (comm == nullptr || environment_comm == MPI_COMM_NULL) {
    MPI_Abort(MPI_COMM_WORLD, 96);
  }

  const ControlOptions options =
    parseControlOptions(argc, argv, environment_comm);

  try {
    const EelTaskConfig config = loadEelTaskConfig(options.task_file);
    EelControlTask task(config);
    comm->setStateActionDims(5, 1);
    comm->setActionScales({ 1.0 }, { -1.0 }, true);

    EelEnvironment environment;
    environment.initialize(environment_comm, options.input_file);
    const std::size_t lagrangian_points =
      environment.globalLagrangianPointCount();
    if (options.fault_after_initialize) {
      throw std::runtime_error("injected failure after IBAMR initialization");
    }

    double forward_velocity = 0.0;
    const double warmup_end = environment.currentTime() +
      config.warmup_cycles * config.decisions_per_baseline_period *
      task.controlInterval();
    environment.setTailBeatFrequencyRatio(1.0);
    while (environment.stepsRemaining() &&
           environment.currentTime() < warmup_end) {
      const double remaining = warmup_end - environment.currentTime();
      const ControlIntervalResult interval =
        environment.advanceControlInterval(
          std::min(task.controlInterval(), remaining));
      forward_velocity = forwardVelocity(interval, config);
    }
    if (!environment.stepsRemaining())
      throw std::runtime_error("eel simulation ended before controlled episode");

    std::array<double, 5> state =
      task.makeState(forward_velocity, environment.currentTailBeatPhase());
    comm->sendInitState(asVector(state));

    const char* terminal_reason = "episode_horizon";
    for (unsigned decision_index = 0;
         decision_index < config.episode_decisions &&
         environment.stepsRemaining();
         ++decision_index) {
      const std::vector<double> action = comm->recvAction();
      if (action.size() != 1)
        throw std::runtime_error("eel control action dimension is not one");

      const ControlDecision decision = task.applyAction(action[0]);
      environment.setTailBeatFrequencyRatio(decision.applied_ratio);
      const ControlIntervalResult interval =
        environment.advanceControlInterval(task.controlInterval());
      forward_velocity = forwardVelocity(interval, config);
      state = task.makeState(forward_velocity,
                             environment.currentTailBeatPhase());
      const RewardBreakdown reward =
        task.reward(forward_velocity, decision.previous_ratio);
      if (!finiteTransition(state, reward))
        throw std::runtime_error("non-finite eel state or reward");

      control_protocol_report.completed_decisions = decision_index + 1;
      control_protocol_report.completed_ibamr_steps += interval.ibamr_steps;
      control_protocol_report.clipped_actions = task.clippedActionCount();
      control_protocol_report.finite_state_and_reward = true;

      const bool terminal =
        decision_index + 1 == config.episode_decisions ||
        !environment.stepsRemaining();
      if (!environment.stepsRemaining()) terminal_reason = "ibamr_end_time";

      int environment_rank = 0;
      MPI_Comm_rank(environment_comm, &environment_rank);
      if (environment_rank == 0) {
        std::printf(
          "EEL_CONTROL decision=%u action=%.17g target_ratio=%.17g "
          "applied_ratio=%.17g start_time=%.17g end_time=%.17g "
          "ibamr_steps=%u forward_velocity=%.17g reward_tracking=%.17g "
          "reward_frequency=%.17g reward_smoothness=%.17g "
          "reward_total=%.17g lagrangian_points=%zu\n",
          decision_index + 1, decision.requested_action,
          decision.target_ratio, decision.applied_ratio,
          interval.start_time, interval.end_time, interval.ibamr_steps,
          forward_velocity, reward.tracking, reward.frequency,
          reward.smoothness, reward.total, lagrangian_points);
        std::fflush(stdout);
      }

      if (terminal) {
        comm->sendTermState(asVector(state), reward.total);
        control_protocol_report.terminal_sent = true;
        if (environment_rank == 0) {
          std::printf(
            "EEL_CONTROL_TERMINAL decisions=%u ibamr_steps=%u "
            "clipped_actions=%u reason=%s\n",
            control_protocol_report.completed_decisions,
            control_protocol_report.completed_ibamr_steps,
            control_protocol_report.clipped_actions, terminal_reason);
          std::fflush(stdout);
        }
      }
      else {
        comm->sendState(asVector(state), reward.total);
      }

      if (comm->terminateTraining()) break;
    }

    if (control_protocol_report.terminal_sent) {
      awaitTrainingTermination(comm, asVector(state), environment_comm,
                               "speed-tracking");
    }
    if (!control_protocol_report.terminal_sent) {
      throw std::runtime_error(
        "eel speed-tracking episode ended without a terminal transition");
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

ControlProtocolReport lastControlProtocolReport()
{
  return control_protocol_report;
}

} // namespace eel2d
} // namespace ibamr_smarties
