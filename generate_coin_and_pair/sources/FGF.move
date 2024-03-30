module coin_owner::FGF {

    use bapt_framework_mainnet::deployer_v2;
    use std::string;

    struct FGF {}

    fun init_module(sender: &signer) {
        deployer_v2::generate_coin_and_initialize_fee_on_transfer<FGF>(
            sender,
            string::utf8(b"rgrg"),
            string::utf8(b"FGF"),
            8,
            10000000000000000,
            true,
            false,
            0,
            0,
            0,
        );
    }
}
