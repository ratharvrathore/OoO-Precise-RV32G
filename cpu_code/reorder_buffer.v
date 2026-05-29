module reorder_buffer (
    input wire clk,
    input wire reset,

    //data collection
    input wire [3:0] tagA, tagB,
    //collections from the decode phase
    input wire [1:0] type,
    input wire [4:0] Rd,
    input wire [31:0] MemAddr,
    input wire [31:0] DataIn,
    input wire [31:0] PcPlus4,
    input wire Exception,
    
    input wire [2:0] next_sch_tag,

    //Inputs from the reorder phase
    input wire [31:0] dataROphase,
    input wire [2:0] SchTagROphase,

    //data into the scheduler phase
    output reg [31:0] dataTagA, dataTagB,
    output reg availableA, availableB,
    output reg [2:0] schTagA, schTagB, //the tags IN THE SCHEDULER to be reffered to if data is not available

    //next steps into the WB phase
    output reg PreciseExceptionFlag,
    output reg [31:0] DataOut,
    output reg [4:0] RdOut,

    //other
    output wire [3:0] next_tag
);
    //there will 2 sets of regs that will together act like each row of the ROB
    //one set will be updated in when an instruction enters the decode phase
    //This is going to also update the youngest pointer
    //The youngest pointer points to entry right after the most recent entry
    //The oldest will point to the least recent entry. When the entry pointed by old is valid, we will push past it, writing to reg in the process if need be and updating old value
    //hence when old == young, the ROB is empty
    //the index of the youngest will also be broadcast to the reg file as next_tag
    //When ROB is empty, the WB phase will be paused. 
    //There will be an empty flag, which will stay high as long as old == young
    //There will also be a full flag, in which case, the decode phase will be paused till the full flag goes down
    //each ROB row will store the following data
    //{valid, type, Rd, MemAddr, Data, PcPlus4, Exception?, Scheduler_Tag}
    //type will determine if the instruciton is execution (Ex: ADD, SUB, float instruction), load, store, jump
    //During deocde, we will write to type, Rd, MemAddr, PcPlus4, and Scheduler Tag, and set valid to 0
    //For the reorder phase, we will write to Data, Ready, Exception and if values are retrived, we will set valid to high
    //In the writeback phase, which is completely independent of the reorder phase, we will write the oldest if the oldest entry's valid is high

    //scheduler and ROB have a line called next_sch_tag which is responsible for telling what to write in the scheduler tag
    //Writes in the reg file will only occur via the ROB, no other way

    //Also add how to deal with nextSignal_decode, cause if we do not and we wait multiple cycles, the ROB will be filled with garbage after all cycles other than the first
endmodule