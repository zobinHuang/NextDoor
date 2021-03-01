#include "testBase.h"

#include <stdlib.h>

#define NUM_ROOT_VERTICES 100

class MultiRWSample
{
public:
  int rootVertices[NUM_ROOT_VERTICES];
  int lastRootIdx;
};

struct MultiRWApp {
  __host__ __device__ int steps() {return 100;}

  __host__ __device__ 
  int stepSize(int k) {
    return 1;
  }

  template<typename SampleType, typename EdgeArray, typename WeightArray>
  __device__ inline
  VertexID next(int step, CSRPartition* csr, const VertexID* transit, const VertexID sampleIdx,
                SampleType* sample, 
                const float max_weight,
                EdgeArray& transitEdges, WeightArray& transitEdgeWeights,
                const EdgePos_t numEdges, const VertexID_t neighbrID, curandState* state)
  {
    if (numEdges == 1) {
      VertexID_t v = transitEdges[0];
      if (step > 0) {
        sample->rootVertices[sample->lastRootIdx] = v;
      }

      return transitEdges[0];
    }
    
    EdgePos_t x = RandNumGen::rand_int(state, numEdges);
    VertexID_t v = transitEdges[x];

    if (step > 0) {
      sample->rootVertices[sample->lastRootIdx] = v;
    }

    return v;
  }

  __host__ __device__ int samplingType()
  {
    return SamplingType::IndividualNeighborhood;
  }

  __host__ __device__ OutputFormat outputFormat()
  {
    return SampledVertices;
  }

  __host__ __device__ EdgePos_t numSamples(CSR* graph)
  {
    return graph->get_n_vertices();
  }

  template<class SampleType>
  __host__ std::vector<VertexID_t> initialSample(int sampleIdx, CSR* graph, SampleType& sample)
  {
    std::vector<VertexID_t> initialValue;
    initialValue.push_back(sample.rootVertices[0]);

    return initialValue;
  }

  __host__ __device__ EdgePos_t initialSampleSize(CSR* graph)
  {
    return 1;
  }

  __host__ __device__ bool hasExplicitTransits()
  {
    return true;
  }

  template<class SampleType>
  __device__ VertexID_t stepTransits(int step, const VertexID_t sampleID, SampleType& sample, int transitIdx, curandState* randState)
  {
    CSRPartition* csr = (CSRPartition*)&csrPartitionBuff[0];
    //Use rejection sampling to sample based on the degree of vertices.
    int x = RandNumGen::rand_int(randState, NUM_ROOT_VERTICES);
    //printf("x %d\n", x);
    sample.lastRootIdx = x;
    return sample.rootVertices[x];
  }

  template<class SampleType>
  __host__ SampleType initializeSample(CSR* graph, const VertexID_t sampleID)
  {
    SampleType sample;
    //printf("sample %d\n", sampleID);
    for (int i = 0; i < NUM_ROOT_VERTICES; i++) {
      sample.rootVertices[i] = rand() % graph->get_n_vertices();
      // if (sampleID + i < graph->get_n_vertices()) {
      //   sample.rootVertices[i] = sampleID + i;
      // } else {
      //   sample.rootVertices[i] = sampleID;
      // }
    }
    return sample;
  }
};

#define RUNS 1
#define CHECK_RESULTS false
#define VERTICES_PER_SAMPLE 0
#include "../check_results.cu"

template<class SampleType, typename App>
bool checkMultiRWResult(NextDoorData<SampleType, App>& nextDoorData)
{
  //Check result by traversing all sampled neighbors and making
  //sure that if neighbors at kth-hop is an adjacent vertex of one
  //of the k-1th hop neighbors.
  CSR* csr = nextDoorData.csr;
  auto& initialSamples = nextDoorData.initialContents;
  auto finalSampleSize = getFinalSampleSize<MultiRWApp>();
  auto& finalSamples = nextDoorData.hFinalSamples;
  auto INVALID_VERTEX = nextDoorData.INVALID_VERTEX;
  auto& samples = nextDoorData.samples;
  int maxSteps = 4;

  //First create the adjacency matrix.
  std::cout << "checking results" << std::endl;
  AdjMatrix adj_matrix;

  csrToAdjMatrix(csr, adj_matrix);

  //Now check the correctness
  size_t numNeighborsToSampleAtStep = 0;
  
  for (int step = 0; step < min(maxSteps, MultiRWApp().steps()); step++) {
    if (step == 0) { 
      bool foundError = false;
      #pragma omp parallel for shared(foundError)
      for (size_t s = 0; s < finalSamples.size(); s += finalSampleSize) {
        std::unordered_set<VertexID_t> uniqueNeighbors;
        // printf("omp_get_num_threads() %d\n", omp_get_num_threads());
        const size_t sampleId = s/finalSampleSize;
        size_t contentsLength = 0;
        if (MultiRWApp().stepSize(step) != ALL_NEIGHBORS) {
          for (size_t v = s + numNeighborsToSampleAtStep; v < s + MultiRWApp().stepSize(step); v++) {
            VertexID_t transit = finalSamples[v];
            uniqueNeighbors.insert(transit);
            contentsLength += (int)(transit != INVALID_VERTEX);

            bool foundInRootVertices = false;
            for (int ii = 0; ii < NUM_ROOT_VERTICES; ii++) {
              VertexID_t rv = samples[sampleId].rootVertices[ii];
              if (adj_matrix[rv].count(transit) == 1) {
                foundInRootVertices = true;
                break;
              }
            }

            if (!foundError && transit != INVALID_VERTEX &&
                !foundInRootVertices) {
              printf("%s:%d Invalid '%d' in Sample '%ld' at Step '%d'\n", __FILE__, __LINE__, transit, sampleId, step);
              foundError = true;
            }
          }

          if (!foundError && contentsLength == 0) {
            printf("Step %d: '%ld' vertices sampled for sample '%ld' but sum of edges of all vertices in sample is '%ld'\n", 
                    step, contentsLength, sampleId, adj_matrix[samples[sampleId].rootVertices[0]].size());
            foundError = true;
          }
        } 
      }

      if (foundError) return false;
    } else {
      bool foundError = false;
      #pragma omp parallel for shared(foundError)
      for (size_t s = 0; s < finalSamples.size(); s += finalSampleSize) {
        const size_t sampleId = s/finalSampleSize;
        size_t contentsLength = 0;
        size_t sumEdgesOfNeighborsAtPrevStep = 0;
        const VertexID_t initialVal = samples[sampleId].rootVertices[0];

        for (size_t v = s + numNeighborsSampledAtStep<MultiRWApp>(step-2); v < s + numNeighborsSampledAtStep<MultiRWApp>(step-1); v++) {
          sumEdgesOfNeighborsAtPrevStep +=  adj_matrix[finalSamples[v]].size();
        }
        
        // if (sampleId == 48) {
        //   printf("step %d start %d end %d\n", step, numNeighborsSampledAtStep(step-1),
        //          ((step == steps() - 1) ? finalSampleSize : numNeighborsSampledAtStep(step)));
        // }
        for (size_t v = s + numNeighborsSampledAtStep<MultiRWApp>(step-1); 
             v < s + ((step == MultiRWApp().steps() - 1) ? finalSampleSize : numNeighborsSampledAtStep<MultiRWApp>(step)); v++) {
          VertexID_t transit = finalSamples[v];
          contentsLength += (int)(transit != INVALID_VERTEX);
          
          bool foundInRootVertices = false;
          for (auto rv : samples[sampleId].rootVertices) {
            if (adj_matrix[rv].count(transit) == 1) {
              foundInRootVertices = true;
              break;
            }
          }

          if (transit != INVALID_VERTEX) {
            if (!foundError && !foundInRootVertices) {
              printf("%s:%d Invalid '%d' in Sample '%ld' at Step '%d'\n", __FILE__, __LINE__, transit, sampleId, step);
              std::cout << "Contents of sample : [";
              for (size_t v2 = s; v2 < s + finalSampleSize; v2++) {
                std::cout << finalSamples[v2] << ", ";
              }
              std::cout << "]" << std::endl;
              foundError = true;
            }
          }
        }

        if (!foundError && contentsLength == 0 && sumEdgesOfNeighborsAtPrevStep > 0) {
          printf("Step %d: '%ld' vertices sampled for sample '%ld' but sum of edges of all vertices in sample is '%ld'\n", 
                  step, contentsLength, sampleId, sumEdgesOfNeighborsAtPrevStep);
          std::cout << "Contents of sample : [";
          for (size_t v2 = s; v2 < s + finalSampleSize; v2++) {
            std::cout << finalSamples[v2] << ", ";
          }
          std::cout << "]" << std::endl;
          foundError = true;
        }
      }

      if (foundError) return false;
    }

    numNeighborsToSampleAtStep = stepSizeAtStep<MultiRWApp>(step);
  }

  return true;
}

APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, LiveJournalTP, LJ1_PATH, RUNS, CHECK_RESULTS, 
               checkMultiRWResult, "TransitParallel", false)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, LiveJournalLB, LJ1_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "TransitParallel", true)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, LiveJournalSP, LJ1_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "SampleParallel", false)

APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, OrkutTP, ORKUT_PATH, RUNS, CHECK_RESULTS, 
               checkMultiRWResult, "TransitParallel", false)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, OrkutLB, ORKUT_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "TransitParallel", true)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, OrkutSP, ORKUT_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "SampleParallel", false)

APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, PatentsTP, PATENTS_PATH, RUNS, CHECK_RESULTS, 
               checkMultiRWResult, "TransitParallel", false)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, PatentsLB, PATENTS_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "TransitParallel", true)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, PatentsSP, PATENTS_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "SampleParallel", false)

APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, RedditTP, REDDIT_PATH, RUNS, CHECK_RESULTS, 
               checkMultiRWResult, "TransitParallel", false)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, RedditLB, REDDIT_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "TransitParallel", true)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, RedditSP, REDDIT_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "SampleParallel", false)

APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, PPITP, PPI_PATH, RUNS, CHECK_RESULTS, 
               checkMultiRWResult, "TransitParallel", false)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, PPILB, PPI_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "TransitParallel", true)
APP_TEST_BINARY(MultiRWSample, MultiRW, MultiRWApp, PPISP, PPI_PATH, RUNS, CHECK_RESULTS, 
                checkMultiRWResult, "SampleParallel", false)