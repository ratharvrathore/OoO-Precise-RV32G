//Cache controller is just the controller for the cache (duh)
//now since we will use BRAM blocks for the cache, it really does not matter how many bits is per storage point
//If each BRAM address stores 1 byte, then just take 4 BRAM and store a part in each, not that deep
//nevertheless, we can use M9K RAM (SRAM not BRAM) for the Cyclone IV

module cache_control (

    //to be continued after I successfully build central_mem_org
);
    
endmodule