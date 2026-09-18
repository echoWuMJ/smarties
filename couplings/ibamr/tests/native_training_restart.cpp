#include "smarties/Core/Agent.h"
#include "smarties/ReplayMemory/MemoryBuffer.h"
#include "smarties/Network/Optimizer.h"
#include "smarties/Engine.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

using namespace smarties;
static void check(bool ok, const char* what) { if(!ok) throw std::runtime_error(what); }
template<class T> auto saveAgent(T& a, const std::string& p, int)
  -> decltype(a.saveAgentState(p), void()) { a.saveAgentState(p); }
template<class T> void saveAgent(T&, const std::string&, long) {
  throw std::runtime_error("Agent checkpoint API missing");
}
template<class T> auto loadAgent(T& a, const std::string& p, int)
  -> decltype(a.restoreAgentState(p), void()) { a.restoreAgentState(p); }
template<class T> void loadAgent(T&, const std::string&, long) {
  throw std::runtime_error("Agent restore API missing");
}
template<class T> auto saveReplay(T& a, const std::string& p, int)
  -> decltype(a.saveTrainingState(p), void()) { a.saveTrainingState(p); }
template<class T> void saveReplay(T&, const std::string&, long) {
  throw std::runtime_error("Replay checkpoint API missing");
}
template<class T> auto loadReplay(T& a, const std::string& p, int)
  -> decltype(a.restoreTrainingState(p), void()) { a.restoreTrainingState(p); }
template<class T> void loadReplay(T&, const std::string&, long) {
  throw std::runtime_error("Replay restore API missing");
}
static MDPdescriptor descriptor() {
  MDPdescriptor m;
  m.dimState = m.dimStateObserved = 2; m.dimAction = 1; m.policyVecDim = 2;
  m.bStateVarObserved = {true,true}; m.bActionSpaceBounded = {false};
  m.lowerActionValue = {-1}; m.upperActionValue = {1};
  m.stateMean = {0,0}; m.stateStdDev = m.stateScale = {1,1};
  return m;
}
static void protocol(int argc, char** argv) {
  Engine engine(MPI_COMM_WORLD,argc,argv);
  check(engine.parse()==0,"Engine parse failed");
  engine.setRedirectAppScreenOutput(false);
  engine.run([](Communicator* c) {
    int rank=0; MPI_Comm_rank(MPI_COMM_WORLD,&rank);
    const std::string control=std::getenv("SMARTIES_PAIRED_CONTROL");
    const std::string dest=std::getenv("NATIVE_TEST_DEST");
    const char* restore=std::getenv("SMARTIES_PAIRED_RESTORE");
    c->setStateActionDims(2,1); c->finalizeProblemDescription();
    if(restore) {
      loadAgent(*c,std::string(restore)+"/proxy"+std::to_string(rank),0);
      c->sendState({6,7},0.75); // must append, never send INIT after restore
    } else {
      c->sendInitState({1,2});
      if(!std::getenv("NATIVE_TEST_WARMUP")) {
        for(int i=0;i<6;++i) c->sendState({double(i+2),double(i+3)},0.25);
        c->sendTermState({8,9},1);
        c->sendInitState({4,5});
      }
    }
    saveAgent(*c,dest+"/proxy"+std::to_string(rank),0);
    int parked=1;
    if(rank==2) MPI_Send(&parked,1,MPI_INT,1,4321,MPI_COMM_WORLD);
    if(rank==1) {
      MPI_Recv(&parked,1,MPI_INT,2,4321,MPI_COMM_WORLD,MPI_STATUS_IGNORE);
      { std::ofstream req(control+"/learner.request"); req << dest << '\n'; }
      bool ready=false;
      for(int i=0;i<10000;++i) {
        std::ifstream r(control+"/learner.ready"); std::string value;
        if(r && std::getline(r,value) && value==dest) { ready=true; break; }
        std::ifstream e(control+"/learner.error");
        if(e) { std::string message; std::getline(e,message); throw std::runtime_error(message); }
        usleep(1000);
      }
      check(ready,"learner did not checkpoint while proxies parked");
      { std::ofstream stop(control+"/learner.stop"); stop << "stop\n"; }
      check(unlink((control+"/learner.request").c_str())==0,"cannot release checkpoint");
      MPI_Send(&parked,1,MPI_INT,2,4322,MPI_COMM_WORLD);
    } else MPI_Recv(&parked,1,MPI_INT,1,4322,MPI_COMM_WORLD,MPI_STATUS_IGNORE);
  });
}
int main(int argc, char** argv) {
  int provided; MPI_Init_thread(&argc, &argv, MPI_THREAD_MULTIPLE, &provided);
  int result = 0;
  try {
    if(std::getenv("NATIVE_TEST_DEST")) {
      protocol(argc,argv); MPI_Finalize(); return 0;
    }
    ExecutionInfo d(MPI_COMM_WORLD, argc, argv);
    d.learners_train_comm = MPI_COMM_SELF; d.bIsMaster = true;
    d.learnersOnWorkers = false; d.nAgents = 1; d.nThreads = 1;
    d.generators = {std::mt19937(91)}; omp_set_num_threads(1);
    auto m = descriptor(); Agent a(0,0,0,m), b(0,0,0,m);
    std::mt19937 seed(27); a.initializeActionSampling(seed);
    a.update(INIT, std::vector<double>{1,2}, 0);
    a.update(CONT, std::vector<double>{3,4}, 0.25);
    a.setAction(Rvec{0.125}, Rvec{0.1,0.2});
    a.learnerTimeStepID = 31; a.learnerGradStepID = 7;
    a.distribution(a.generator); // leaves the cached second Gaussian populated
    saveAgent(a, "native-agent.bin", 0); loadAgent(b, "native-agent.bin", 0);
    check(b.sOld == std::vector<double>({1,2}) && b.state == std::vector<double>({3,4}), "Agent state history lost");
    check(b.action == a.action && b.policyVector == a.policyVector, "pending action/policy lost");
    check(b.timeStepInEpisode == 1 && b.learnerGradStepID == 7 && b.learnerTimeStepID == 31, "Agent counters lost");
    for(int i=0;i<32;++i) check(a.sampleActionNoise() == b.sampleActionNoise(), "cached Gaussian/RNG continuation differs");
    HyperParameters hp(2,1); hp.returnsEstimator = "none";
    MemoryBuffer rm(m,hp,d), restored(m,hp,d);
    Agent ep(0,0,0,m); ep.initializeActionSampling(seed);
    ep.update(INIT, std::vector<double>{1,2}, 0); rm.storeState(ep);
    rm.agentToMinibatch(0).appendValues(0,0); ep.setAction(Rvec{0.1},Rvec{0.1,0.2}); rm.storeAction(ep);
    ep.update(TERM, std::vector<double>{2,3}, 1); rm.storeState(ep);
    rm.agentToMinibatch(0).appendValues(0); rm.terminateCurrentEpisode(ep);
    ep.update(INIT, std::vector<double>{4,5}, 0); rm.storeState(ep);
    rm.agentToMinibatch(0).appendValues(0.5,0.7); ep.setAction(Rvec{0.2},Rvec{0.2,0.3}); rm.storeAction(ep);
    rm.counters.nGradSteps = 17; rm.counters.nGatheredB4Startup = 9;
    rm.get(0).priorityImpW[0] = 0.625; rm.StateRewRdx.partialret[0] = 12.75;
    saveReplay(rm,"native-replay.bin",0); loadReplay(restored,"native-replay.bin",0);
    check(restored.nStoredEps()==1 && restored.nGradSteps()==17, "replay counters changed");
    check(restored.counters.nGatheredB4Startup==9 && restored.get(0).priorityImpW[0]==0.625, "replay metadata lost");
    check(restored.StateRewRdx.partialret[0]==12.75, "reducer partial lost");
    ep.update(CONT, std::vector<double>{6,7}, 0.75); restored.storeState(ep);
    check(restored.getInProgress(0).states.size()==2 && restored.getInProgress(0).states[0][0]==4, "CONT did not extend active trajectory");
    check(restored.getInProgress(0).rewards.back()==0.75, "continued reward lost");
    { std::ofstream out("native-truncated.bin",std::ios::binary); out << "short"; }
    bool rejected=false; try { loadAgent(b,"native-truncated.bin",0); } catch(const std::exception&) { rejected=true; }
    check(rejected,"truncated checkpoint accepted");
    auto incompatible=descriptor(); incompatible.upperActionValue[0]=2;
    Agent wrongMDP(0,0,0,incompatible);
    rejected=false;
    try { loadAgent(wrongMDP,"native-agent.bin",0); } catch(const std::exception&) { rejected=true; }
    check(rejected,"changed action scaling accepted on restart");
    hp.batchSize=1; hp.targetDelay=3; hp.nnLambda=0;
    auto w=std::make_shared<Parameters>(std::vector<Uint>{2},std::vector<Uint>{0},1);
    auto w2=w->allocateEmptyAlike(), g=w->allocateEmptyAlike(), g2=w->allocateEmptyAlike();
    w->clear(); w2->clear();
    AdamOptimizer opt(hp,d,w,{g}), opt2(hp,d,w2,{g2});
    const auto step=[](AdamOptimizer& o,const ParametersPtr_t& grad) {
      grad->params[0]=0.375; grad->params[1]=-0.125; grad->written=true;
      o.prepare_update({}); o.apply_update();
    };
    for(int i=0;i<4;++i) step(opt,g);
    saveReplay(opt,"native-optimizer.bin",0); loadReplay(opt2,"native-optimizer.bin",0);
    check(opt2.nStep==4,"optimizer step lost");
    step(opt,g); step(opt2,g2);
    for(Uint i=0;i<w->nParams;++i) {
      check(w->params[i]==w2->params[i],"next Adam update differs");
      check(opt.getWeights(-1)->params[i]==opt2.getWeights(-1)->params[i],"target update phase differs");
    }
    std::cout << "native training checkpoint roundtrip PASS\n";
  } catch(const std::exception& e) { std::cerr << e.what() << '\n'; result=1; }
  MPI_Finalize(); return result;
}
