#pragma once

#include "gfa_parser.hpp" // from gfa_compression
#include <cstdint>
#include <handlegraph/mutable_path_mutable_handle_graph.hpp>

namespace odgi {

void gfa_graph_to_handle(GfaGraph &gfa_graph,
                         handlegraph::MutablePathMutableHandleGraph *graph,
                         bool compact_ids, uint64_t n_threads,
                         bool show_progress);

}
