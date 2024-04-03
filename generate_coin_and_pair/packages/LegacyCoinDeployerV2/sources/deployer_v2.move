/*
    Tool for deploying coins and creating liquidity pools in baptswap v2.1 in a single transaction.
    - The deployer is initialized with a fee that is paid in APT
    - The deployer is initialized with an admin address that can change the fee and admin address

    - TODOs:   
*/

module bapt_framework_mainnet::deployer_v2 {

    use aptos_framework::coin::{Self, BurnCapability, FreezeCapability};
    use aptos_framework::aptos_coin::{AptosCoin as APT};
    use aptos_framework::event;
    use aptos_std::type_info;
    use baptswap_v2dot1::fee_on_transfer_v2dot1;
    use baptswap_v2dot1::router_v2dot1;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    // ------
    // Errors
    // ------

    /// The deployer has not been initialized
    const EDEPLOYER_NOT_INITIALIZED: u64 = 0;
    /// The signer is not the bapt framework
    const ENOT_BAPT_ACCOUNT: u64 = 1;
    /// There is not enough X supply to create the LP
    const EINSUFFICIENT_X_SUPPLY: u64 = 2;
    /// There is not enough Y supply to create the LP
    const EINSUFFICIENT_Y_SUPPLY: u64 = 3;
    /// The signer does not have enough APT to pay the fee
    const EINSUFFICIENT_APT_BALANCE: u64 = 4;
    /// The inputted admin is the same as the old admin
    const ESAME_ADMIN: u64 = 5;
    /// The inputted fee is the same as the old fee
    const ESAME_FEE: u64 = 6;
    /// The coin is not burnable
    const ECOIN_NOT_BURNABLE: u64 = 7;
    /// The coin is not freezable
    const ECOIN_NOT_FREEZABLE: u64 = 8;
    
    // ---------
    // Resources
    // ---------

    /// Global storage for the deployer config info
    struct Config has key {
        admin: address,
        deploy_and_liquidate_fee: u64,
        deploy_and_initialize_fee_on_transfer_fee: u64
    }

    /// Global storage for the coins capabilities
    struct Caps<phantom CoinType> has key {
        burn_cap: Option<BurnCapability<CoinType>>,
        freeze_cap: Option<FreezeCapability<CoinType>>
    }
    
    // ------
    // Events
    // ------

    #[event]
    struct BurnCapCreated has drop, store { cointype: String }

    #[event]
    struct FreezeCapCreated has drop, store { cointype: String }

    #[event]
    struct DeployAndLiquidateFeeUpdated has drop, store { old_fee: u64, new_fee: u64 }

    #[event]
    struct DeployAndCreatePairFeeUpdated has drop, store { old_fee: u64, new_fee: u64 }

    #[event]
    struct AdminUpdated has drop, store { old_admin: address, new_admin: address }

    #[event]
    struct CoinsBurned has drop, store { cointype: String, amount: u64 }

    #[event]
    struct CoinsFrozen has drop, store { cointype: String, amount: u64 }

    // -----------
    // Initializer
    // -----------

    entry fun init(signer_ref: &signer, deploy_and_liquidate_fee: u64, deploy_and_initialize_fee_on_transfer_fee: u64) {
        let signer_addr = signer::address_of(signer_ref);
        assert!(signer_addr == @bapt_framework_mainnet, ENOT_BAPT_ACCOUNT);
        // init config
        move_to<Config>(
            signer_ref,
            Config {
                admin: signer_addr,
                deploy_and_liquidate_fee,
                deploy_and_initialize_fee_on_transfer_fee
            }
        );
    }

    // -----------
    // Public APIs
    // -----------

    /// Deploy a coin and create an LP for <CoinType, Y>
    public entry fun generate_coin_and_liquidate<CoinType, Y>(
        deployer: &signer,
        // coin specific parameters
        name: String,
        symbol: String,
        decimals: u8,
        total_supply: u64,
        burnable: bool,
        freezable: bool,
        // fee_on_transfer specific parameters
        liquidity_fee: u128,
        rewards_fee: u128,
        team_fee: u128,
        // LP specific parameters
        amount_x_desired: u64,
        amount_y_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64
    ) acquires Config {
        assert_config_initialized();
        // assert total_supply >= amount_x_desired
        assert!(total_supply >= amount_x_desired, EINSUFFICIENT_X_SUPPLY);
        if (type_info::type_of<Y>() == type_info::type_of<APT>()) {
            // assert amount_y_desired >= amount_y_min
            assert!(coin::balance<Y>(signer::address_of(deployer)) >= amount_y_desired + deploy_and_liquidate_fee(), EINSUFFICIENT_Y_SUPPLY);
        } else {
            // assert balance >= amount y desired
            assert!(coin::balance<Y>(signer::address_of(deployer)) >= amount_y_desired, EINSUFFICIENT_Y_SUPPLY);
            // assert deployer has enough APT to pay the fee
            assert!(coin::balance<APT>(signer::address_of(deployer)) >= deploy_and_liquidate_fee(), EINSUFFICIENT_APT_BALANCE);
        };
        // create coin
        generate_coin<CoinType>(deployer, name, symbol, decimals, total_supply, burnable, freezable);
        // initialize fee_on_transfer
        fee_on_transfer_v2dot1::initialize_fee_on_transfer<CoinType>(
            deployer,
            liquidity_fee,
            rewards_fee,
            team_fee
        );
        // create pair and add liquidity
        router_v2dot1::add_liquidity<CoinType, Y>(
            deployer,
            amount_x_desired,
            amount_y_desired,
            amount_x_min,
            amount_y_min
        );

        // collect fees
        collect_deploy_and_liquidate_fee(deployer);
    }

    /// Deploy a coin and initialize fee-on-transfer for it
    public entry fun generate_coin_and_initialize_fee_on_transfer<CoinType>(
        deployer: &signer,
        // coin specific parameters
        name: String,
        symbol: String,
        decimals: u8,
        total_supply: u64,
        burnable: bool,
        freezable: bool,
        // fee_on_transfer specific parameters
        liquidity_fee: u128,
        rewards_fee: u128,
        team_fee: u128
    ) acquires Config {
        assert_config_initialized();
        // create coin
        generate_coin<CoinType>(deployer, name, symbol, decimals, total_supply, burnable, freezable);
        // initialize fee_on_transfer
        fee_on_transfer_v2dot1::initialize_fee_on_transfer<CoinType>(
            deployer,
            liquidity_fee,
            rewards_fee,
            team_fee
        );

        // collect fees
        collect_deploy_and_initialize_fee_on_transfer_fee(deployer);
    }
    

    /// Burn an amount of a CoinType
    public entry fun burn<CoinType>(signer_ref: &signer, amount: u64) acquires Caps {
        assert_config_initialized();
        assert!(is_burnable<CoinType>(), ECOIN_NOT_BURNABLE);
        // burn
        let to_burn = coin::withdraw<CoinType>(signer_ref, amount);
        coin::burn<CoinType>(to_burn, burn_cap<CoinType>());
        // emit burn event
        event::emit(CoinsBurned { cointype: type_info::type_name<CoinType>(), amount });
    }

    /// Freeze a CoinStore in an account address of a CoinType
    public entry fun freeze_account_coinstore<CoinType>(acc_addr: address) acquires Caps {
        assert_config_initialized();
        assert!(is_freezable<CoinType>(), ECOIN_NOT_FREEZABLE);
        coin::freeze_coin_store<CoinType>(acc_addr, freeze_cap<CoinType>());
        // emit freeze event
        event::emit(
            CoinsFrozen { 
                cointype: type_info::type_name<CoinType>(), 
                amount: coin::balance<CoinType>(acc_addr) 
            }
        );
    }

    #[view]
    /// Get the current admin
    public fun admin(): address acquires Config {
        assert_config_initialized();
        borrow_global<Config>(@bapt_framework_mainnet).admin
    }

    #[view]
    /// Get the current fee for deploy and liquidate
    public fun deploy_and_liquidate_fee(): u64 acquires Config {
        borrow_global<Config>(@bapt_framework_mainnet).deploy_and_liquidate_fee
    }

    #[view]
    /// Get the current fee for deploy and create pair
    public fun deploy_and_initialize_fee_on_transfer_fee(): u64 acquires Config {
        borrow_global<Config>(@bapt_framework_mainnet).deploy_and_initialize_fee_on_transfer_fee
    }

    #[view]
    /// Get coin owner
    public fun coin_owner<CoinType>(): address {
        assert_config_initialized();
        let type_info = type_info::type_of<CoinType>();
        type_info::account_address(&type_info)
    }

    #[view]
    /// Check if a coin is burnable
    public fun is_burnable<CoinType>(): bool acquires Caps {
        assert_config_initialized();
        option::is_some(&borrow_global<Caps<CoinType>>(coin_owner<CoinType>()).burn_cap)
    }

    #[view]
    /// Check if a coin is freezable
    public fun is_freezable<CoinType>(): bool acquires Caps {
        assert_config_initialized();
        option::is_some(&borrow_global<Caps<CoinType>>(coin_owner<CoinType>()).freeze_cap)
    }

    #[view]
    /// Get a vec of caps for a given coin
    public fun get_caps<CoinType>(): vector<String> acquires Caps {
        assert_config_initialized();
        let caps = vector::empty<String>();
        if (is_burnable<CoinType>()) {
            vector::push_back(&mut caps, string::utf8(b"burn_cap"));
        };
        if (is_freezable<CoinType>()) {
            vector::push_back(&mut caps, string::utf8(b"freeze_cap"));
        };
        caps
    }
    
    // --------
    // Mutators
    // --------

    /// Change the admin
    public entry fun set_admin(signer_ref: &signer, new_admin: address) acquires Config {
        assert_config_initialized();
        let signer_addr = signer::address_of(signer_ref);
        let config = borrow_global_mut<Config>(@bapt_framework_mainnet);
        assert!(config.admin == signer_addr, ENOT_BAPT_ACCOUNT);
        // assert new_admin is not same as old admin
        let old_admin = config.admin;
        assert!(old_admin != new_admin, ESAME_ADMIN);
        config.admin = new_admin;
        // emit change admin event
        event::emit(AdminUpdated { old_admin, new_admin });
    }

    /// Change the fee for deploy and liquidate 
    public entry fun set_deploy_and_liquidate_fee(signer_ref: &signer, new_fee: u64) acquires Config {
        assert_config_initialized();
        let signer_addr = signer::address_of(signer_ref);
        let config = borrow_global_mut<Config>(@bapt_framework_mainnet);
        assert!(config.admin == signer_addr, ENOT_BAPT_ACCOUNT);
        // assert new_fee is not same as old fee
        let old_fee = config.deploy_and_liquidate_fee;
        assert!(old_fee != new_fee, ESAME_FEE);
        config.deploy_and_liquidate_fee = new_fee;
        // emit change fee event
        event::emit(DeployAndLiquidateFeeUpdated { old_fee, new_fee });
    }

    /// Change the fee for deploy and create pair
    public entry fun set_deploy_and_initialize_fee_on_transfer_fee(signer_ref: &signer, new_fee: u64) acquires Config {
        assert_config_initialized();
        let signer_addr = signer::address_of(signer_ref);
        let config = borrow_global_mut<Config>(@bapt_framework_mainnet);
        assert!(config.admin == signer_addr, ENOT_BAPT_ACCOUNT);
        // assert new_fee is not same as old fee
        let old_fee = config.deploy_and_initialize_fee_on_transfer_fee;
        assert!(old_fee != new_fee, ESAME_FEE);
        config.deploy_and_initialize_fee_on_transfer_fee = new_fee;
        // emit change fee event
        event::emit(DeployAndCreatePairFeeUpdated { old_fee, new_fee });
    }

    // ----------------
    // Helper Functions
    // ----------------

    inline fun assert_config_initialized() {
        assert!(exists<Config>(@bapt_framework_mainnet), EDEPLOYER_NOT_INITIALIZED);
    }

    inline fun generate_coin<CoinType>(
        deployer: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        total_supply: u64,
        burnable: bool,
        freezable: bool
    ) {
        // generate coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<CoinType>(
            deployer, 
            name, 
            symbol, 
            decimals, 
            true
        );
        coin::register<CoinType>(deployer);
        // mint 
        let coins_minted = coin::mint(total_supply, &mint_cap);
        coin::deposit(signer::address_of(deployer), coins_minted);
        // destroy mint cap
        coin::destroy_mint_cap<CoinType>(mint_cap);
        // deal freeze and burn caps
        let maybe_burn_cap = if (burnable) { 
            // emit burn cap created event 
            event::emit(BurnCapCreated { cointype: name });
            option::some(burn_cap) 
        } else { 
            coin::destroy_burn_cap<CoinType>(burn_cap);
            option::none() 
        };
        let maybe_freeze_cap = if (freezable) { 
            // emit freeze cap created event
            event::emit(FreezeCapCreated { cointype: name });
            option::some(freeze_cap) 
        } else { 
            coin::destroy_freeze_cap<CoinType>(freeze_cap);
            option::none() 
        };
        move_to<Caps<CoinType>>(
            deployer,
            Caps {
                burn_cap: maybe_burn_cap,
                freeze_cap: maybe_freeze_cap
            }
        );
    }
    
    inline fun collect_deploy_and_liquidate_fee(deployer: &signer) acquires Config {
        let fee = borrow_global<Config>(@bapt_framework_mainnet).deploy_and_liquidate_fee;
        coin::transfer<APT>(deployer, @bapt_framework_mainnet, fee);
    }

    inline fun collect_deploy_and_initialize_fee_on_transfer_fee(deployer: &signer) acquires Config {
        let fee = borrow_global<Config>(@bapt_framework_mainnet).deploy_and_initialize_fee_on_transfer_fee;
        coin::transfer<APT>(deployer, @bapt_framework_mainnet, fee);
    }

    // returns the burn cap for a coin
    inline fun burn_cap<CoinType>(): &BurnCapability<CoinType> acquires Caps {
        option::borrow(&borrow_global<Caps<CoinType>>(coin_owner<CoinType>()).burn_cap)
    }

    // returns the freeze cap for a coin
    inline fun freeze_cap<CoinType>(): &FreezeCapability<CoinType> acquires Caps {
        option::borrow(&borrow_global<Caps<CoinType>>(coin_owner<CoinType>()).freeze_cap)
    }

}