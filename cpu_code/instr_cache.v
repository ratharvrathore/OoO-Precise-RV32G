module instr_cache (
    input wire clk,
    input wire [31:0] instruction_address,
    output wire [31:0] instruction
);
    reg [31:0] reg instruction_cache [0:31];

    initial begin
        $readmemb("code.mem", instruction_ram);
    end

    assign instruction = instruction_ram[instruction_address];
endmodule