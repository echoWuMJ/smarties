#include "smarties/Network/Builder.h"
#include "smarties/Network/Network.h"
#include "smarties/Network/NetworkAudit.h"
#include "smarties/Network/Optimizer.h"
#include "smarties/Settings/ExecutionInfo.h"
#include "smarties/Settings/HyperParameters.h"

#include <mpi.h>
#include <omp.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace
{
using smarties::Builder;
using smarties::ExecutionInfo;
using smarties::HyperParameters;
using smarties::Network;
using smarties::ParameterAudit;
using smarties::Parameters;
using smarties::Real;
using smarties::Uint;
using smarties::nnReal;

struct Options
{
  Uint threads = 0;
  Uint updates = 0;
  Uint seed = 0;
  std::string audit_file;
  std::string checkpoint_dir;
  std::string restart_dir;
};

struct Sample
{
  std::vector<Real> state;
  nnReal target = 0;
};

struct RunData
{
  Uint threads = 0;
  Uint requested_updates = 0;
  Uint start_step = 0;
  Uint final_step = 0;
  std::map<Uint, long double> losses;
  std::map<std::string, std::string> audit_digests;
  std::map<std::string, int> audit_finite;
  std::vector<long double> parameters;
  std::vector<long double> predictions;
};

Uint parseUint(const std::string& text, const std::string& name)
{
  std::size_t used = 0;
  const unsigned long value = std::stoul(text, &used, 10);
  if (used != text.size() || value > std::numeric_limits<Uint>::max())
    throw std::runtime_error("invalid " + name + ": " + text);
  return static_cast<Uint>(value);
}

Options parseOptions(int argc, char** argv)
{
  Options options;
  for (int i = 1; i < argc; ++i)
  {
    const std::string arg(argv[i]);
    if (i + 1 >= argc) throw std::runtime_error("missing value for " + arg);
    const std::string value(argv[++i]);
    if (arg == "--threads") options.threads = parseUint(value, "threads");
    else if (arg == "--updates") options.updates = parseUint(value, "updates");
    else if (arg == "--seed") options.seed = parseUint(value, "seed");
    else if (arg == "--audit-file") options.audit_file = value;
    else if (arg == "--checkpoint-dir") options.checkpoint_dir = value;
    else if (arg == "--restart-dir") options.restart_dir = value;
    else throw std::runtime_error("unknown option: " + arg);
  }
  if (options.threads != 1 && options.threads != 4)
    throw std::runtime_error("--threads must be 1 or 4");
  if (options.updates == 0) throw std::runtime_error("--updates must be positive");
  if (options.seed == 0) throw std::runtime_error("--seed must be positive");
  if (options.audit_file.empty()) throw std::runtime_error("--audit-file is required");
  if (!options.checkpoint_dir.empty() && !options.restart_dir.empty())
    throw std::runtime_error("checkpoint and restart modes are mutually exclusive");
  return options;
}

std::vector<Sample> fixedSamples()
{
  std::vector<Sample> samples(64);
  for (Uint i = 0; i < samples.size(); ++i)
  {
    samples[i].state.resize(5);
    for (Uint j = 0; j < 5; ++j)
    {
      const int raw = static_cast<int>((17 * i + 31 * j + 7) % 101) - 50;
      samples[i].state[j] = static_cast<Real>(raw) / Real(50);
    }
    const nnReal value = static_cast<nnReal>(
        Real(0.60) * samples[i].state[0]
      - Real(0.25) * samples[i].state[1]
      + Real(0.15) * samples[i].state[2]);
    samples[i].target = std::max(nnReal(-0.8), std::min(nnReal(0.8), value));
  }
  return samples;
}

long double meanSquaredError(const Network& net,
                             const std::vector<Sample>& samples,
                             std::vector<long double>* predictions = nullptr)
{
  long double loss = 0;
  if (predictions) predictions->clear();
  std::unique_ptr<smarties::Activation> activation = net.allocActivation();
  for (const Sample& sample : samples)
  {
    const std::vector<Real> output = net.forward(sample.state, activation.get());
    const long double prediction = output.at(0);
    const long double error = prediction - sample.target;
    loss += error * error;
    if (predictions) predictions->push_back(prediction);
  }
  return loss / static_cast<long double>(samples.size());
}

void writeParameterFile(const Parameters* const parameters,
                        const std::string& path)
{
  std::ofstream file(path.c_str(), std::ios::binary | std::ios::trunc);
  if (!file) throw std::runtime_error("cannot write checkpoint: " + path);
  const std::uint64_t count = parameters->nParams;
  const std::uint64_t bytes = sizeof(nnReal);
  file.write(reinterpret_cast<const char*>(&count), sizeof(count));
  file.write(reinterpret_cast<const char*>(&bytes), sizeof(bytes));
  file.write(reinterpret_cast<const char*>(parameters->params),
             static_cast<std::streamsize>(count * bytes));
  if (!file) throw std::runtime_error("short checkpoint write: " + path);
}

int readParameterFile(const Parameters* const parameters, const std::string& path)
{
  std::ifstream file(path.c_str(), std::ios::binary);
  if (!file) return 1;
  std::uint64_t count = 0, bytes = 0;
  file.read(reinterpret_cast<char*>(&count), sizeof(count));
  file.read(reinterpret_cast<char*>(&bytes), sizeof(bytes));
  if (!file || count != parameters->nParams || bytes != sizeof(nnReal)) return 2;
  file.read(reinterpret_cast<char*>(parameters->params),
            static_cast<std::streamsize>(count * bytes));
  return file ? 0 : 3;
}

Uint readStep(const std::string& directory)
{
  std::ifstream file((directory + "/step.txt").c_str());
  unsigned long value = 0;
  if (!(file >> value) || value > std::numeric_limits<Uint>::max())
    throw std::runtime_error("invalid restart step in " + directory);
  return static_cast<Uint>(value);
}

void saveStep(const std::string& directory, Uint step)
{
  std::ofstream file((directory + "/step.txt").c_str(), std::ios::trunc);
  if (!(file << step << '\n'))
    throw std::runtime_error("cannot write checkpoint step in " + directory);
}

void emitAudit(std::ofstream& output,
               const std::string& stage,
               Uint step,
               Uint threads,
               const Parameters& parameters)
{
  const ParameterAudit audit = smarties::auditParameters(parameters);
  output << smarties::formatParameterAudit(stage, "fixed_regression", step,
                                            threads, audit) << '\n';
}

void emitFinalRecords(std::ofstream& output,
                      Uint step,
                      const Parameters& parameters,
                      const std::vector<long double>& predictions)
{
  output << std::setprecision(std::numeric_limits<long double>::max_digits10);
  for (Uint i = 0; i < parameters.nParams; ++i)
    output << "SMARTIES_NETWORK_PARAMETER step=" << step << " index=" << i
           << " value=" << static_cast<long double>(parameters.params[i]) << '\n';
  for (Uint i = 0; i < predictions.size(); ++i)
    output << "SMARTIES_NETWORK_PREDICTION step=" << step << " sample=" << i
           << " value=" << predictions[i] << '\n';
}

int runProbe(const Options& options, int argc, char** argv)
{
  int provided = MPI_THREAD_SINGLE;
  if (MPI_Init_thread(&argc, &argv, MPI_THREAD_MULTIPLE, &provided) != MPI_SUCCESS)
    throw std::runtime_error("MPI_Init_thread failed");
  if (provided < MPI_THREAD_MULTIPLE)
  {
    MPI_Finalize();
    throw std::runtime_error("MPI thread support below MULTIPLE");
  }

  int result = 0;
  try
  {
    omp_set_dynamic(0);
    omp_set_num_threads(static_cast<int>(options.threads));
    {
      ExecutionInfo distrib(MPI_COMM_WORLD, argc, argv);
      distrib.nThreads = options.threads;
      distrib.nMasters = 1;
      distrib.nEnvironments = 1;
      distrib.workerProcessesPerEnv = 0;
      distrib.randSeed = options.seed;
      distrib.learnersOnWorkers = false;
      distrib.forkableApplication = true;
      distrib.initialze();
      distrib.figureOutWorkersPattern();
      // ExecutionInfo advances generator zero while deriving per-thread seeds.
      // Reset only the probe's network-initialization stream so thread-count
      // comparisons start from the same weights.
      distrib.generators.at(0).seed(options.seed);

      HyperParameters settings(5, 1);
      settings.batchSize = 64;
      settings.learnrate = 1e-2;
      settings.nnLambda = 0;
      settings.epsAnneal = 0;
      settings.targetDelay = 0;
      settings.outWeightsPrefac = 1;

      Builder builder(settings, distrib);
      builder.addInput(5);
      builder.addLayer(16, "Tanh");
      builder.addLayer(16, "Tanh");
      builder.addLayer(1, "Linear", true);
      builder.build();
      builder.opt->bAnnealLearnRate = false;

      const std::vector<Sample> samples = fixedSamples();
      std::ofstream audit(options.audit_file.c_str(), std::ios::trunc);
      if (!audit) throw std::runtime_error("cannot create audit file");
      audit << std::setprecision(std::numeric_limits<long double>::max_digits10);

      Uint start_step = 0;
      emitAudit(audit, "initial", 0, options.threads,
                *builder.opt->getWeights(0));
      if (!options.restart_dir.empty())
      {
        start_step = readStep(options.restart_dir);
        const std::string base = options.restart_dir + "/network";
        const int restart_status = builder.opt->restart(
          [](const Parameters* const p, const std::string path) {
            return readParameterFile(p, path);
          }, base);
        if (restart_status != 0)
          throw std::runtime_error("optimizer restart failed");
        builder.opt->setStep(start_step);
        emitAudit(audit, "reload", start_step, options.threads,
                  *builder.opt->getWeights(0));
      }

      audit << "SMARTIES_NETWORK_RUN requested_updates=" << options.updates
            << " start_step=" << start_step
            << " final_step=" << start_step + options.updates
            << " threads=" << options.threads
            << " seed=" << options.seed
            << " precision_bytes=" << sizeof(nnReal) << '\n';

      const long double initial_loss = meanSquaredError(*builder.net, samples);
      audit << "SMARTIES_NETWORK_LOSS step=" << start_step
            << " mean_squared_error=" << initial_loss
            << " finite=" << (std::isfinite(initial_loss) ? 1 : 0) << '\n';

      std::vector<std::unique_ptr<smarties::Activation>> activations;
      for (Uint thread = 0; thread < options.threads; ++thread)
        activations.emplace_back(builder.net->allocActivation());

      for (Uint local_update = 1; local_update <= options.updates; ++local_update)
      {
        #pragma omp parallel for schedule(static) num_threads(options.threads)
        for (int sample_index = 0;
             sample_index < static_cast<int>(samples.size()); ++sample_index)
        {
          const Uint thread = static_cast<Uint>(omp_get_thread_num());
          const Sample& sample = samples[static_cast<Uint>(sample_index)];
          const std::vector<Real> prediction =
            builder.net->forward(sample.state, activations[thread].get());
          const std::vector<nnReal> error(1,
            static_cast<nnReal>(sample.target - prediction[0]));
          builder.net->backProp(error, activations[thread].get(),
                                builder.threadGrads[thread].get());
        }
        builder.opt->prepare_update({});
        while (!builder.opt->ready2UpdateWeights()) { }
        builder.opt->apply_update();

        const Uint step = start_step + local_update;
        const long double loss = meanSquaredError(*builder.net, samples);
        audit << "SMARTIES_NETWORK_LOSS step=" << step
              << " mean_squared_error=" << loss
              << " finite=" << (std::isfinite(loss) ? 1 : 0) << '\n';
        if (local_update == 1 || local_update == options.updates)
          emitAudit(audit, "update", step, options.threads,
                    *builder.opt->getWeights(0));
      }

      const Uint final_step = start_step + options.updates;
      std::vector<long double> predictions;
      meanSquaredError(*builder.net, samples, &predictions);
      emitFinalRecords(audit, final_step, *builder.opt->getWeights(0), predictions);

      if (!options.checkpoint_dir.empty())
      {
        const std::string base = options.checkpoint_dir + "/network";
        builder.opt->save(
          [](const Parameters* const p, const std::string path, const bool) {
            writeParameterFile(p, path);
          }, base, false);
        saveStep(options.checkpoint_dir, final_step);
      }
    }
  }
  catch (...)
  {
    if (MPI_Finalize() != MPI_SUCCESS) { }
    throw;
  }
  if (MPI_Finalize() != MPI_SUCCESS) result = 1;
  return result;
}

std::map<std::string, std::string> parseFields(const std::string& line)
{
  std::map<std::string, std::string> fields;
  std::istringstream stream(line);
  std::string token;
  stream >> token;
  while (stream >> token)
  {
    const std::size_t separator = token.find('=');
    if (separator != std::string::npos)
      fields[token.substr(0, separator)] = token.substr(separator + 1);
  }
  return fields;
}

RunData readRun(const std::string& path)
{
  std::ifstream file(path.c_str());
  if (!file) throw std::runtime_error("cannot read audit: " + path);
  RunData run;
  std::string line;
  while (std::getline(file, line))
  {
    const std::map<std::string, std::string> fields = parseFields(line);
    if (line.find("SMARTIES_NETWORK_RUN ") == 0)
    {
      run.threads = parseUint(fields.at("threads"), "threads");
      run.requested_updates = parseUint(fields.at("requested_updates"), "updates");
      run.start_step = parseUint(fields.at("start_step"), "start step");
      run.final_step = parseUint(fields.at("final_step"), "final step");
    }
    else if (line.find("SMARTIES_NETWORK_AUDIT ") == 0)
    {
      const std::string key = fields.at("stage") + ":" + fields.at("step");
      run.audit_digests[key] = fields.at("digest");
      run.audit_finite[key] = std::stoi(fields.at("finite"));
    }
    else if (line.find("SMARTIES_NETWORK_LOSS ") == 0)
    {
      const Uint step = parseUint(fields.at("step"), "loss step");
      run.losses[step] = std::stold(fields.at("mean_squared_error"));
      if (std::stoi(fields.at("finite")) != 1)
        run.audit_finite["loss:" + fields.at("step")] = 0;
    }
    else if (line.find("SMARTIES_NETWORK_PARAMETER ") == 0)
      run.parameters.push_back(std::stold(fields.at("value")));
    else if (line.find("SMARTIES_NETWORK_PREDICTION ") == 0)
      run.predictions.push_back(std::stold(fields.at("value")));
  }
  if (run.threads == 0 || run.parameters.empty() || run.predictions.size() != 64)
    throw std::runtime_error("malformed audit: " + path);
  return run;
}

int fail(const std::string& kind,
         const std::string& field,
         long double left = 0,
         long double right = 0,
         long double difference = 0,
         long double tolerance = 0)
{
  std::cout << std::setprecision(std::numeric_limits<long double>::max_digits10)
            << kind << " field=" << field
            << " left=" << left << " right=" << right
            << " abs_diff=" << difference << " tolerance=" << tolerance << '\n';
  return 1;
}

int failText(const std::string& kind,
             const std::string& field,
             const std::string& left,
             const std::string& right)
{
  std::cout << kind << " field=" << field
            << " left=" << left << " right=" << right
            << " abs_diff=NA tolerance=NA\n";
  return 1;
}

bool sameTextFile(const std::string& left, const std::string& right)
{
  std::ifstream a(left.c_str(), std::ios::binary), b(right.c_str(), std::ios::binary);
  std::ostringstream as, bs;
  as << a.rdbuf(); bs << b.rdbuf();
  return as.str() == bs.str();
}

int compareRuns(int argc, char** argv)
{
  if (argc != 9) throw std::runtime_error("--compare requires seven audit files");
  const RunData repeat_a = readRun(argv[2]);
  const RunData repeat_b = readRun(argv[3]);
  const RunData threaded = readRun(argv[4]);
  const RunData long_run = readRun(argv[5]);
  const RunData checkpoint = readRun(argv[6]);
  const RunData resumed = readRun(argv[7]);
  const RunData continuous = readRun(argv[8]);
  const std::vector<const RunData*> runs = {
    &repeat_a, &repeat_b, &threaded, &long_run,
    &checkpoint, &resumed, &continuous
  };

  for (Uint r = 0; r < runs.size(); ++r)
    for (const auto& finite : runs[r]->audit_finite)
      if (finite.second != 1)
        return fail("NONFINITE_UPDATE", "run" + std::to_string(r) + ":" + finite.first);

  if (!sameTextFile(argv[2], argv[3]))
    return failText("DETERMINISM_MISMATCH", "one_thread_repeat",
                    "repeat_a", "repeat_b");

  const std::string initial = repeat_a.audit_digests.at("initial:0");
  for (Uint r = 1; r < runs.size(); ++r)
    if (runs[r]->audit_digests.at("initial:0") != initial)
      return failText("DETERMINISM_MISMATCH",
                      "initial_digest_run" + std::to_string(r), initial,
                      runs[r]->audit_digests.at("initial:0"));

  if (repeat_a.final_step != 1 || threaded.final_step != 1)
    return fail("THREADED_UPDATE_MISMATCH", "one_update_count");
  if (repeat_a.parameters.size() != threaded.parameters.size())
    return fail("THREADED_UPDATE_MISMATCH", "parameter_count");
  const long double atol = 1e-6L, rtol = 1e-5L;
  for (Uint i = 0; i < repeat_a.parameters.size(); ++i)
  {
    const long double left = repeat_a.parameters[i];
    const long double right = threaded.parameters[i];
    const long double difference = std::fabs(left - right);
    const long double tolerance = atol + rtol * std::fabs(right);
    if (difference > tolerance)
      return fail("THREADED_UPDATE_MISMATCH", "parameter[" + std::to_string(i) + "]",
                  left, right, difference, tolerance);
  }
  for (Uint i = 0; i < repeat_a.predictions.size(); ++i)
  {
    const long double left = repeat_a.predictions[i];
    const long double right = threaded.predictions[i];
    const long double difference = std::fabs(left - right);
    const long double tolerance = atol + rtol * std::fabs(right);
    if (difference > tolerance)
      return fail("THREADED_UPDATE_MISMATCH", "prediction[" + std::to_string(i) + "]",
                  left, right, difference, tolerance);
  }

  if (long_run.start_step != 0 || long_run.final_step != 200 ||
      long_run.losses.size() != 201)
    return fail("NO_FIXED_DATA_CONVERGENCE", "long_update_count");
  long double first = 0, last = 0;
  for (Uint step = 1; step <= 20; ++step) first += long_run.losses.at(step);
  for (Uint step = 181; step <= 200; ++step) last += long_run.losses.at(step);
  first /= 20; last /= 20;
  if (last > 0.25L * first)
    return fail("NO_FIXED_DATA_CONVERGENCE", "last20_over_first20",
                last, first, last, 0.25L * first);

  if (checkpoint.final_step != 7 || resumed.start_step != 7 ||
      resumed.final_step != 8 || continuous.final_step != 8)
    return fail("CHECKPOINT_MISMATCH", "checkpoint_step_count");
  if (checkpoint.audit_digests.at("update:7") !=
      resumed.audit_digests.at("reload:7"))
    return failText("CHECKPOINT_MISMATCH", "reload_digest",
                    checkpoint.audit_digests.at("update:7"),
                    resumed.audit_digests.at("reload:7"));
  if (resumed.audit_digests.at("update:8") !=
      continuous.audit_digests.at("update:8"))
    return failText("CHECKPOINT_MISMATCH", "continued_digest",
                    resumed.audit_digests.at("update:8"),
                    continuous.audit_digests.at("update:8"));
  for (Uint i = 0; i < resumed.predictions.size(); ++i)
  {
    const long double left = resumed.predictions[i];
    const long double right = continuous.predictions[i];
    if (left != right)
      return fail("CHECKPOINT_MISMATCH",
                  "continued_prediction[" + std::to_string(i) + "]",
                  left, right, std::fabs(left - right), 0);
  }

  std::cout << "PASS\n";
  return 0;
}
} // namespace

int main(int argc, char** argv)
{
  try
  {
    if (argc > 1 && std::string(argv[1]) == "--compare")
      return compareRuns(argc, argv);
    return runProbe(parseOptions(argc, argv), argc, argv);
  }
  catch (const std::exception& error)
  {
    std::cerr << "network update probe fatal: " << error.what() << '\n';
    return 64;
  }
}
