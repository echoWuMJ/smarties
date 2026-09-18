//
//  smarties
//  Copyright (c) 2018 CSE-Lab, ETH Zurich, Switzerland. All rights reserved.
//  Distributed under the terms of the MIT license.
//
//  Created by Guido Novati (novatig@ethz.ch).
//

#include "Learner_approximator.h"

#include "../Network/Approximator.h"
#include "../Network/Builder.h"
#include "../Network/NetworkAudit.h"
#include "../Utils/ParameterBlob.h"

#include <cerrno>
#include <chrono>
#include <fstream>
#include <sys/stat.h>

namespace smarties
{

namespace
{
void createDirectoriesAbsolute(const std::string& path)
{
  if(path.empty() || path.front() != '/')
    die("Learner audit directory must be absolute.");

  for(std::size_t pos=1; pos<=path.size(); ++pos)
  {
    if(pos < path.size() && path[pos] != '/') continue;
    const std::string directory = path.substr(0, pos);
    if(directory.empty()) continue;
    if(mkdir(directory.c_str(), S_IRWXU | S_IRWXG) == 0) continue;

    struct stat info;
    if(errno == EEXIST && stat(directory.c_str(), &info) == 0 &&
       S_ISDIR(info.st_mode)) continue;
    _die("Failed to create learner audit directory %s.", directory.c_str());
  }
}
} // namespace

Learner_approximator::Learner_approximator(MDPdescriptor& MDP_,
                                           HyperParameters& S_,
                                           ExecutionInfo& D_) :
                                           Learner(MDP_, S_, D_)
{}

Learner_approximator::~Learner_approximator()
{
  for(auto & net : networks) {
    if(net not_eq nullptr) {
      delete net;
      net = nullptr;
    }
  }
}

void Learner_approximator::spawnTrainTasks()
{
  if(settings.bSampleEpisodes && data->nStoredEps() < (long) settings.batchSize)
    die("Parameter minTotObsNum is too low for given problem");
  if(!settings.bSampleEpisodes && nObsB4StartTraining<(long)settings.batchSize)
    die("Parameter minTotObsNum is too low for given problem");

  profiler->start("SAMP");
  debugL("Sample the replay memory");
  const Uint batchSize=settings.batchSize_local, ESpopSize=settings.ESpopSize;
  const Uint nThr = distrib.nThreads, CS =  batchSize / nThr;
  const MiniBatch MB = data->sampleMinibatch(batchSize, nGradSteps() );
  profiler->stop();

  debugL("Compute the gradients");
  if(settings.bSampleEpisodes)
  {
    #pragma omp parallel for collapse(2) schedule(dynamic,1) num_threads(nThr)
    for (Uint wID=0; wID<ESpopSize; ++wID)
    for (Uint bID=0; bID<batchSize; ++bID) {
      const Uint thrID = omp_get_thread_num();
      for (const auto & net : networks ) net->load(MB, bID, wID);
      Train(MB, wID, bID);
      // backprop, from last net to first for dependencies in gradients:
      if(thrID==0) profiler->stop_start("BCK");
      for (const auto & net : Utilities::reverse(networks) ) net->backProp(bID);
      if(thrID==0) profiler->stop();
    }
  }
  else
  {
    #pragma omp parallel for collapse(2) schedule(static,CS) num_threads(nThr)
    for (Uint wID=0; wID<ESpopSize; ++wID)
    for (Uint bID=0; bID<batchSize; ++bID) {
      const Uint thrID = omp_get_thread_num();
      for (const auto & net : networks ) net->load(MB, bID, wID);
      Train(MB, wID, bID);
      // backprop, from last net to first for dependencies in gradients:
      if(thrID==0) profiler->stop_start("BCK");
      for (const auto & net : Utilities::reverse(networks) ) net->backProp(bID);
      if(thrID==0) profiler->stop();
    }
  }

  if(ESpopSize>1) {
    debugL("Compute objective function for CMA optimizer.");
    prepareCMALoss();
  }

  profiler->start("ADDW");
  debugL("Reduce gradient estimates");
  for(const auto & net : networks) {
    net->prepareUpdate();
    net->updateGradStats(learner_name, nGradSteps());
  }
  profiler->stop();
}

void Learner_approximator::checkpoint(TrainingCheckpoint& ar)
{
  Learner::checkpoint(ar);
  ar.expect(static_cast<Uint>(networks.size()));
  for(auto* net:networks) net->checkpoint(ar);
}

void Learner_approximator::prepareCMALoss()
{

}

void Learner_approximator::applyGradient()
{
  profiler->start("GRAD");
  debugL("Apply SGD update");
  for(Uint networkID=0; networkID<networks.size(); ++networkID) {
    networks[networkID]->applyUpdate();
    emitNetworkAudit("update", networkID);
  }
  profiler->stop();
}

void Learner_approximator::emitNetworkAudit(const std::string& stage,
                                            const Uint networkID) const
{
  if(distrib.learnerAuditDir == "none") return;
  if(learn_rank != 0) return;
  if(networkID >= networks.size()) die("Invalid network audit index.");

  createDirectoriesAbsolute(distrib.learnerAuditDir);
  std::ofstream output(distrib.learnerAuditDir + "/learner_audit.log",
                       std::ios::out | std::ios::app);
  if(!output) die("Failed to open learner audit log.");

  Optimizer* const optimizer = networks[networkID]->getOptimizerPtr();
  const ParameterAudit audit = auditParameters(*optimizer->getWeights(0));
  output << formatParameterAudit(stage,
                                 learner_name + "_network" +
                                   std::to_string(networkID),
                                 optimizer->nStep, nThreads, audit)
         << '\n';
  if(!output) die("Failed to write learner audit log.");
}

void Learner_approximator::saveAuditCheckpoint(const std::string& stage) const
{
  if(distrib.learnerAuditDir == "none") return;
  if(learn_rank != 0) return;

  const std::string directory = distrib.learnerAuditDir + "/" + stage;
  createDirectoriesAbsolute(directory);
  const std::string base = directory + "/" + learner_name;
  for(const auto& net : networks) net->save(base, false);
  data->save(base);
}

void Learner_approximator::onTrainingInitialized()
{
  for(Uint networkID=0; networkID<networks.size(); ++networkID)
    emitNetworkAudit("initialized", networkID);
  saveAuditCheckpoint("initial");
}

void Learner_approximator::onTrainingFinalized()
{
  for(Uint networkID=0; networkID<networks.size(); ++networkID)
  {
    const unsigned long optimizerStep =
      networks[networkID]->getOptimizerPtr()->nStep;
    if(optimizerStep != static_cast<unsigned long>(nGradSteps()))
      _die("Learner audit step mismatch: optimizer=%lu memory=%ld.",
           optimizerStep, nGradSteps());
    emitNetworkAudit("final", networkID);
  }
  saveAuditCheckpoint("final");
}

void Learner_approximator::getMetrics(std::ostringstream& buf) const
{
  Learner::getMetrics(buf);
  for(const auto & net : networks) net->getMetrics(buf);
}
void Learner_approximator::getHeaders(std::ostringstream& buf) const
{
  Learner::getHeaders(buf);
  for(const auto & net : networks) net->getHeaders(buf);
}

void Learner_approximator::restart()
{
  if(distrib.restart == "none") return;
  if(!learn_rank) printf("Restarting from saved policy...\n");

  for(const auto & net : networks) {
    net->restart(distrib.restart+"/"+learner_name);
    net->save("restarted_"+learner_name, false);
  }

  Learner::restart();

  for(Uint networkID=0; networkID<networks.size(); ++networkID) {
    networks[networkID]->setNgradSteps(nGradSteps());
    emitNetworkAudit("restart", networkID);
  }
}

void Learner_approximator::save()
{
  //const Uint currStep = nGradSteps()+1;
  //const Real freqSave = freqPrint * PRFL_DMPFRQ;
  //const Uint freqBackup = std::ceil(settings.saveFreq / freqSave)*freqSave;
  const bool bBackup = false; // currStep % freqBackup == 0;
  for(const auto & net : networks) net->save(learner_name, bBackup);

  Learner::save();
}

// Create preprocessing network, which contains conv layers requested by env
// and some shared fully connected layers, read from vector nnLayerSizes
// from settings. The last privateLayersNum sizes of nnLayerSizes are not
// added here because we assume those sizes will parameterize the approximators
// that take the output of the preprocessor and produce policies,values, etc.
bool Learner_approximator::createEncoder()
{
  auto & encoderLayers = settings.encoderLayerSizes;
  // remove zero-sized layers: (i.e. if settings reads 'encoderLayerSizes: 0')
  for(Uint i=0; i<encoderLayers.size(); ++i)
    if (encoderLayers[i] == 0)
      encoderLayers.erase(encoderLayers.begin() + i);

  const Uint nPreProcLayers = encoderLayers.size();
  if ( MDP.conv2dDescriptors.size() == 0 and nPreProcLayers == 0 )
    return false; // no preprocessing

  if(networks.size()>0) warn("some network was created before preprocessing");
  networks.push_back(new Approximator("encodr", settings,distrib, data.get()));
  networks.back()->buildPreprocessing(encoderLayers);
  assert( networks.back()->nLayers() > 1 );
  return true;
}

void Learner_approximator::initializeApproximators()
{
  for(const auto& net : networks)
  {
    net->initializeNetwork();
  }
}

void Learner_approximator::setupDataCollectionTasks(TaskQueue& tasks)
{
  params.add(MDP.stateScale.size(), MDP.stateScale.data());
  params.add(MDP.stateMean.size(), MDP.stateMean.data());
  params.add(1, & MDP.rewardsScale);
  params.add(1, & MDP.rewardsMean);
  for(const auto& net : networks)  net->gatherParameters(params);

  Learner::setupDataCollectionTasks(tasks);
}

}

/*

void Learner_approximator::createSharedEncoder(const Uint privateNum)
{
  if(input->net not_eq nullptr) {
    delete input->opt; input->opt = nullptr;
    delete input->net; input->net = nullptr;
  }
  if(input->nOutputs() == 0) return;
  Builder input_build(settings);
  bool bInputNet = false;
  input_build.addInput( input->nOutputs() );
  bInputNet = bInputNet || env->predefinedNetwork(input_build);
  bInputNet = bInputNet || predefinedNetwork(input_build, privateNum);
  if(bInputNet) {
    Network* net = input_build.build(true);
    input->initializeNetwork(net, input_build.opt);
  }
}
//bool Learner::predefinedNetwork(Builder & input_net)
//{
//  return false;
//}
, input(new Encapsulator("input", S_, data))
if(input->nOutputs() == 0) return;
Builder input_build(S);
input_build.addInput( input->nOutputs() );
bool builder_used = env->predefinedNetwork(input_build);
if(builder_used) {
  Network* net = input_build.build(true);
  Optimizer* opt = input_build.opt;
  input->initializeNetwork(net, opt);
}
*/
