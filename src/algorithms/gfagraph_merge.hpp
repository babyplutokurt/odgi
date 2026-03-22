#pragma once

#include "gfa_parser.hpp"
#include "odgi.hpp"

namespace odgi {
namespace algorithms {

// Append a GfaGraph into target with a node ID shift. Returns the max node ID
// in target after appending this graph (or shift_id when no nodes are added).
uint64_t append_gfagraph_with_shift(const GfaGraph& gfa_graph,
                                    graph_t* target,
                                    uint64_t shift_id,
                                    bool add_rank_suffix,
                                    char suffix_separator,
                                    uint64_t input_graph_rank,
                                    uint64_t num_threads);

}
}
