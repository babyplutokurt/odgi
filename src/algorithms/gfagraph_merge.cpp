#include "gfagraph_merge.hpp"

#include <cmath>
#include <string>
#include <utility>
#include <vector>

namespace odgi {
namespace algorithms {

static inline void maybe_add_rank_suffix(std::string& name,
                                         bool add_rank_suffix,
                                         char suffix_separator,
                                         uint64_t input_graph_rank) {
    if (add_rank_suffix) {
        name.push_back(suffix_separator);
        name += std::to_string(input_graph_rank);
    }
}

static inline std::string make_walk_name(const GfaGraph& gfa_graph, size_t i) {
    std::string walk_name = gfa_graph.walks.sample_ids[i] + "#" +
                            std::to_string(gfa_graph.walks.hap_indices[i]) +
                            "#" + gfa_graph.walks.seq_ids[i];
    if (gfa_graph.walks.seq_starts.size() > i &&
        gfa_graph.walks.seq_ends.size() > i &&
        (gfa_graph.walks.seq_starts[i] != -1 ||
         gfa_graph.walks.seq_ends[i] != -1)) {
        walk_name += ":" + std::to_string(gfa_graph.walks.seq_starts[i]) + "-" +
                     std::to_string(gfa_graph.walks.seq_ends[i]);
    }
    return walk_name;
}

uint64_t append_gfagraph_with_shift(const GfaGraph& gfa_graph,
                                    graph_t* target,
                                    uint64_t shift_id,
                                    bool add_rank_suffix,
                                    char suffix_separator,
                                    uint64_t input_graph_rank,
                                    uint64_t num_threads) {

    uint64_t max_id = shift_id;
    if (gfa_graph.node_sequences.size() > 1) {
        for (size_t i = 1; i < gfa_graph.node_sequences.size(); ++i) {
            const uint64_t new_id = shift_id + i;
            target->create_handle(gfa_graph.node_sequences[i], new_id);
            max_id = new_id;
        }
    }

    for (size_t i = 0; i < gfa_graph.links.from_ids.size(); ++i) {
        const uint64_t source_id = shift_id + gfa_graph.links.from_ids[i];
        const uint64_t sink_id = shift_id + gfa_graph.links.to_ids[i];
        const bool source_is_rev = gfa_graph.links.from_orients[i] == '-';
        const bool sink_is_rev = gfa_graph.links.to_orients[i] == '-';
        target->create_edge(target->get_handle(source_id, source_is_rev),
                            target->get_handle(sink_id, sink_is_rev));
    }

    std::vector<std::pair<path_handle_t, const std::vector<NodeId>*>> path_jobs;
    path_jobs.reserve(gfa_graph.paths.size() + gfa_graph.walks.size());

    for (size_t i = 0; i < gfa_graph.paths.size(); ++i) {
        std::string path_name = gfa_graph.path_names[i];
        maybe_add_rank_suffix(path_name, add_rank_suffix, suffix_separator,
                              input_graph_rank);
        path_jobs.emplace_back(target->create_path_handle(path_name),
                               &gfa_graph.paths[i]);
    }

    for (size_t i = 0; i < gfa_graph.walks.size(); ++i) {
        std::string walk_name = make_walk_name(gfa_graph, i);
        maybe_add_rank_suffix(walk_name, add_rank_suffix, suffix_separator,
                              input_graph_rank);
        path_jobs.emplace_back(target->create_path_handle(walk_name),
                               &gfa_graph.walks.walks[i]);
    }

#pragma omp parallel for schedule(dynamic, 1) num_threads(num_threads)
    for (size_t i = 0; i < path_jobs.size(); ++i) {
        const auto& path_job = path_jobs[i];
        for (const NodeId node_id : *(path_job.second)) {
            const uint64_t node_abs_id = shift_id + std::abs(node_id);
            const bool is_rev = node_id < 0;
            target->append_step(path_job.first, target->get_handle(node_abs_id, is_rev));
        }
    }

    return max_id;
}

}
}
