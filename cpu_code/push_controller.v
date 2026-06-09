module push_controller (
    input  wire fetch_valid,
    input  wire scheduler_full,
    input  wire rob_full,

    input  wire scheduler_empty,
    input  wire alu_busy,

    input  wire execute_valid,
    input  wire mem_required,
    input  wire mem_done,

    output wire push_fetch,
    output wire push_schedule,
    output wire push_reorder,
    output wire advance_fetch
);
    assign push_fetch    = fetch_valid && !scheduler_full && !rob_full;
    assign push_schedule = !scheduler_empty && !alu_busy;
    assign push_reorder  = execute_valid && (!mem_required || mem_done);
    assign advance_fetch = push_fetch;
endmodule
