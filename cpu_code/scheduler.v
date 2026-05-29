module scheduler (
    input wire clk, reset,

    input wire [31:0] dataA, dataB,
    input wire [2:0] tagA, tagB,
    input wire availableA, availableB,
    //Remember that the value could've been retrived from reg file so there is some logic in between to be taken care of

    input wire [31:0] instruciton,
    //along with the entry, there will be some basic data reagrding the instruction that is being performed.
    //instead of instruction itself, we can use the control varibales also
    //For now it is 32 bits, it may be less

    //Inputs from the reorder phase
    input wire [31:0] dataROphase,
    input wire [2:0] SchTagROphase,

    input wire nextSignal_schedule, //This wire comes from the next/flush logic. When we get this, push

    output reg [31:0] dataOut1, dataOut2, //to the ALU
    output reg [31:0] ControlVars, //The control variables needed up ahead in the pipeline, including stuff like ALUControl etc

);
    //Also has old, young pointers to find if full or empty
    //Whichever instruction from old to new is the first to get ready will get pushed if we can push
    //The scheduler works in the following pattern:
    //An all the data is sent from the ROB and the reg file with some combinational logic in between

    //Assume for the instruction ADD R3, R1, R2
    //In the deocde phase, valid of R3 was set to low and the tag in the reg file points to the ROB
    //Now, in the ROB, there lies a tag pointing to the respective scheduler tag from which the result generates
    //If the value of the R1 and R2 does not exist, then they point to the ROB also where if it does not exist again it points to some tag in scheduler which will gernerate its result
    //we will then write that value in the tag region 
    //Note that scheduler itself is the transition from D to S and then to E
endmodule