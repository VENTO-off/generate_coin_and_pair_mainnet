/// Uniswap v2 like token swap program
module baptswap::swap {
    use std::signer;
    use std::option;
    use std::string;
    use aptos_std::type_info;
    use aptos_std::event;

    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_framework::resource_account;
    use aptos_framework::code;

    use baptswap::math;
    use baptswap::swap_utils;
    use baptswap::u256;

    friend baptswap::router;

    const ZERO_ACCOUNT: address = @zero;
    const DEFAULT_ADMIN: address = @default_admin;
    const RESOURCE_ACCOUNT: address = @baptswap;
    const DEV: address = @dev;
    const MINIMUM_LIQUIDITY: u128 = 1000;
    const MAX_COIN_NAME_LENGTH: u64 = 32;

    // List of errors
    const ERROR_ONLY_ADMIN: u64 = 0;
    const ERROR_ALREADY_INITIALIZED: u64 = 1;
    const ERROR_NOT_CREATOR: u64 = 2;
    const ERROR_INSUFFICIENT_LIQUIDITY_MINTED: u64 = 4;
    const ERROR_INSUFFICIENT_AMOUNT: u64 = 6;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 7;
    const ERROR_INVALID_AMOUNT: u64 = 8;
    const ERROR_TOKENS_NOT_SORTED: u64 = 9;
    const ERROR_INSUFFICIENT_LIQUIDITY_BURNED: u64 = 10;
    const ERROR_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 13;
    const ERROR_INSUFFICIENT_INPUT_AMOUNT: u64 = 14;
    const ERROR_K: u64 = 15;
    const ERROR_X_NOT_REGISTERED: u64 = 16;
    const ERROR_Y_NOT_REGISTERED: u64 = 16;
    const ERROR_NOT_ADMIN: u64 = 17;
    const ERROR_NOT_FEE_TO: u64 = 18;
    const ERROR_NOT_EQUAL_EXACT_AMOUNT: u64 = 19;
    const ERROR_NOT_RESOURCE_ACCOUNT: u64 = 20;
    const ERROR_NO_FEE_WITHDRAW: u64 = 21;
    const ERROR_EXCESSIVE_FEE: u64 = 22;

    const PRECISION: u64 = 10000;

    /// Max `u128` value.
    const MAX_U128: u128 = 340282366920938463463374607431768211455;

    const BASE_LIQUIDITY_FEE: u128 = 20;

    struct BaptSwapCoin {}

    /// The LP Token type
    struct LPToken<phantom X, phantom Y> has key {}

    /// Stores the metadata required for the token pairs
    struct TokenPairMetadata<phantom X, phantom Y> has key {
        /// The admin of the token pair
        creator: address,
        /// It's reserve_x * reserve_y, as of immediately after the most recent liquidity event
        k_last: u128,
        /// The variable liquidity fee granted to providers
        liquidity_fee: u128,
        /// The BaptSwap treasury fee
        treasury_fee: u128,
        /// The team fee
        team_fee: u128,
        /// The rewards fee
        rewards_fee: u128,
        /// T0 token balance
        balance_x: coin::Coin<X>,
        /// T1 token balance
        balance_y: coin::Coin<Y>,
        /// T0 treasury balance
        treasury_balance_x: coin::Coin<X>,
        /// T1 treasury balance
        treasury_balance_y: coin::Coin<Y>,
        /// T0 team balance
        team_balance_x: coin::Coin<X>,
        /// T1 team balance
        team_balance_y: coin::Coin<Y>,
        /// Mint capacity of LP Token
        mint_cap: coin::MintCapability<LPToken<X, Y>>,
        /// Burn capacity of LP Token
        burn_cap: coin::BurnCapability<LPToken<X, Y>>,
        /// Freeze capacity of LP Token
        freeze_cap: coin::FreezeCapability<LPToken<X, Y>>,
    }

    /// Stores the reservation info required for the token pairs
    struct TokenPairReserve<phantom X, phantom Y> has key {
        reserve_x: u64,
        reserve_y: u64,
        block_timestamp_last: u64
    }

    /// Stores the rewards pool info for token pairs
    struct TokenPairRewardsPool<phantom X, phantom Y> has key {
        pool_balance_x: coin::Coin<X>,
        pool_balance_y: coin::Coin<Y>,
    }

    struct SwapInfo has key {
        signer_cap: account::SignerCapability,
        fee_to: address,
        admin: address,
        pair_created: event::EventHandle<PairCreatedEvent>
    }

    struct PairCreatedEvent has drop, store {
        user: address,
        token_x: string::String,
        token_y: string::String
    }

    struct PairEventHolder<phantom X, phantom Y> has key {
        add_liquidity: event::EventHandle<AddLiquidityEvent<X, Y>>,
        remove_liquidity: event::EventHandle<RemoveLiquidityEvent<X, Y>>,
        swap: event::EventHandle<SwapEvent<X, Y>>,
        change_fee: event::EventHandle<FeeChangeEvent<X, Y>>
    }

    struct AddLiquidityEvent<phantom X, phantom Y> has drop, store {
        user: address,
        amount_x: u64,
        amount_y: u64,
        liquidity: u64,

    }

    struct RemoveLiquidityEvent<phantom X, phantom Y> has drop, store {
        user: address,
        liquidity: u64,
        amount_x: u64,
        amount_y: u64,

    }

    struct SwapEvent<phantom X, phantom Y> has drop, store {
        user: address,
        amount_x_in: u64,
        amount_y_in: u64,
        amount_x_out: u64,
        amount_y_out: u64
    }

    struct FeeChangeEvent<phantom X, phantom Y> has drop, store {
        user: address,
        liquidity_fee: u128,
        team_fee: u128,
        rewards_fee: u128
    }

    /*

     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
     Please use swap_util::sort_token_type<X,Y>()
     before using any function
     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    */

    fun init_module(sender: &signer) {
        let signer_cap = resource_account::retrieve_resource_account_cap(sender, DEV);
        let resource_signer = account::create_signer_with_capability(&signer_cap);
        move_to(&resource_signer, SwapInfo {
            signer_cap,
            fee_to: ZERO_ACCOUNT,
            admin: DEFAULT_ADMIN,
            pair_created: account::new_event_handle<PairCreatedEvent>(&resource_signer),
        });
    }

    public(friend) fun deploy_coin(
        sender: &signer,
        name: vector<u8>,
        symbol: vector<u8>
    ) {
        // let sender_addr = signer::address_of(sender);
        // let swap_info = borrow_global_mut<SwapInfo>(RESOURCE_ACCOUNT);
        // let resource_signer = account::create_signer_with_capability(&swap_info.signer_cap);

        let (_resource, resource_cap) = account::create_resource_account(sender, b"test");
        let resource_signer_from_cap = account::create_signer_with_capability(&resource_cap);

        // now we init the LP token
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<BaptSwapCoin>(
            &resource_signer_from_cap,
            string::utf8(name),
            string::utf8(symbol),
            8,
            true
        );

        coin::destroy_mint_cap(mint_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    /// Create the specified coin pair
    public(friend) fun create_pair<X, Y>(
        sender: &signer,
    ) acquires SwapInfo {
        assert!(!is_pair_created<X, Y>(), ERROR_ALREADY_INITIALIZED);

        let sender_addr = signer::address_of(sender);
        let swap_info = borrow_global_mut<SwapInfo>(RESOURCE_ACCOUNT);
        let resource_signer = account::create_signer_with_capability(&swap_info.signer_cap);

        let lp_name: string::String = string::utf8(b"BaptSwap-");
        let name_x = coin::symbol<X>();
        let name_y = coin::symbol<Y>();
        string::append(&mut lp_name, name_x);
        string::append_utf8(&mut lp_name, b"-");
        string::append(&mut lp_name, name_y);
        string::append_utf8(&mut lp_name, b"-LP");
        if (string::length(&lp_name) > MAX_COIN_NAME_LENGTH) {
            lp_name = string::utf8(b"BaptSwap LPs");
        };

        // now we init the LP token
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<LPToken<X, Y>>(
            &resource_signer,
            lp_name,
            string::utf8(b"BAPT-LP"),
            8,
            true
        );

        move_to<TokenPairReserve<X, Y>>(
            &resource_signer,
            TokenPairReserve {
                reserve_x: 0,
                reserve_y: 0,
                block_timestamp_last: 0
            }
        );

        move_to<TokenPairMetadata<X, Y>>(
            &resource_signer,
            TokenPairMetadata {
                creator: sender_addr,
                k_last: 0,
                liquidity_fee: 0,
                treasury_fee: 10,
                team_fee: 0,
                rewards_fee: 0,
                balance_x: coin::zero<X>(),
                balance_y: coin::zero<Y>(),
                treasury_balance_x: coin::zero<X>(),
                treasury_balance_y: coin::zero<Y>(),
                team_balance_x: coin::zero<X>(),
                team_balance_y: coin::zero<Y>(),
                mint_cap,
                burn_cap,
                freeze_cap,
            }
        );

        move_to<TokenPairRewardsPool<X, Y>>(
            &resource_signer,
            TokenPairRewardsPool {
                pool_balance_x: coin::zero<X>(),
                pool_balance_y: coin::zero<Y>(),
            }
        );

        move_to<PairEventHolder<X, Y>>(
            &resource_signer,
            PairEventHolder {
                add_liquidity: account::new_event_handle<AddLiquidityEvent<X, Y>>(&resource_signer),
                remove_liquidity: account::new_event_handle<RemoveLiquidityEvent<X, Y>>(&resource_signer),
                swap: account::new_event_handle<SwapEvent<X, Y>>(&resource_signer),
                change_fee: account::new_event_handle<FeeChangeEvent<X,Y>>(&resource_signer)
            }
        );

        // pair created event
        let token_x = type_info::type_name<X>();
        let token_y = type_info::type_name<Y>();

        event::emit_event<PairCreatedEvent>(
            &mut swap_info.pair_created,
            PairCreatedEvent {
                user: sender_addr,
                token_x,
                token_y
            }
        );


        // create LP CoinStore , which is needed as a lock for minimum_liquidity
        register_lp<X, Y>(&resource_signer);
    }

    public fun register_lp<X, Y>(sender: &signer) {
        coin::register<LPToken<X, Y>>(sender);
    }

    public fun is_pair_created<X, Y>(): bool {
        exists<TokenPairReserve<X, Y>>(RESOURCE_ACCOUNT)
    }

    /// Obtain the LP token balance of `addr`.
    /// This method can only be used to check other users' balance.
    public fun lp_balance<X, Y>(addr: address): u64 {
        coin::balance<LPToken<X, Y>>(addr)
    }

    /// Get the total supply of LP Tokens
    public fun total_lp_supply<X, Y>(): u128 {
        option::get_with_default(
            &coin::supply<LPToken<X, Y>>(),
            0u128
        )
    }

    /// Get the current fees for a token pair
    public fun token_fees<X, Y>(): (u128) acquires TokenPairMetadata {
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
        (
            metadata.liquidity_fee + metadata.treasury_fee + metadata.team_fee + metadata.rewards_fee
        )
    }

    // Get current accumulated fees for a token pair
    public fun token_fees_accumulated<X, Y>(): (u64, u64, u64, u64, u64, u64) acquires TokenPairMetadata, TokenPairRewardsPool {
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
        let pool = borrow_global_mut<TokenPairRewardsPool<X, Y>>(RESOURCE_ACCOUNT);
        (
            coin::value<X>(&metadata.treasury_balance_x), coin::value<Y>(&metadata.treasury_balance_y),
            coin::value<X>(&metadata.team_balance_x), coin::value<Y>(&metadata.team_balance_y),
            coin::value<X>(&pool.pool_balance_x), coin::value<Y>(&pool.pool_balance_y),
        )
    }

    /// Get the current reserves of T0 and T1 with the latest updated timestamp
    public fun token_reserves<X, Y>(): (u64, u64, u64) acquires TokenPairReserve {
        let reserve = borrow_global<TokenPairReserve<X, Y>>(RESOURCE_ACCOUNT);
        (
            reserve.reserve_x,
            reserve.reserve_y,
            reserve.block_timestamp_last
        )
    }

    /// The amount of balance currently in pools of the liquidity pair
    public fun token_balances<X, Y>(): (u64, u64) acquires TokenPairMetadata {
        let meta =
            borrow_global<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
        (
            coin::value(&meta.balance_x),
            coin::value(&meta.balance_y)
        )
    }

    public fun check_or_register_coin_store<X>(sender: &signer) {
        if (!coin::is_account_registered<X>(signer::address_of(sender))) {
            coin::register<X>(sender);
        };
    }

    public fun admin(): address acquires SwapInfo {
        let swap_info = borrow_global_mut<SwapInfo>(RESOURCE_ACCOUNT);
        swap_info.admin
    }

    public fun fee_to(): address acquires SwapInfo {
        let swap_info = borrow_global_mut<SwapInfo>(RESOURCE_ACCOUNT);
        swap_info.fee_to
    }

    // ===================== Update functions ======================
    /// Add more liquidity to token types. This method explicitly assumes the
    /// min of both tokens are 0.
    public(friend) fun add_liquidity<X, Y>(
        sender: &signer,
        amount_x: u64,
        amount_y: u64
    ): (u64, u64, u64) acquires TokenPairReserve, TokenPairMetadata, PairEventHolder {
        let (a_x, a_y, coin_lp, coin_left_x, coin_left_y) = add_liquidity_direct(coin::withdraw<X>(sender, amount_x), coin::withdraw<Y>(sender, amount_y));
        let sender_addr = signer::address_of(sender);
        let lp_amount = coin::value(&coin_lp);
        assert!(lp_amount > 0, ERROR_INSUFFICIENT_LIQUIDITY);
        check_or_register_coin_store<LPToken<X, Y>>(sender);
        coin::deposit(sender_addr, coin_lp);
        coin::deposit(sender_addr, coin_left_x);
        coin::deposit(sender_addr, coin_left_y);

        let pair_event_holder = borrow_global_mut<PairEventHolder<X, Y>>(RESOURCE_ACCOUNT);
        event::emit_event<AddLiquidityEvent<X, Y>>(
            &mut pair_event_holder.add_liquidity,
            AddLiquidityEvent<X, Y> {
                user: sender_addr,
                amount_x: a_x,
                amount_y: a_y,
                liquidity: lp_amount,
            }
        );

        (a_x, a_y, lp_amount)
    }

    public(friend) fun add_swap_event<X, Y>(
        sender: &signer,
        amount_x_in: u64,
        amount_y_in: u64,
        amount_x_out: u64,
        amount_y_out: u64
    ) acquires PairEventHolder {
        let sender_addr = signer::address_of(sender);
        let pair_event_holder = borrow_global_mut<PairEventHolder<X, Y>>(RESOURCE_ACCOUNT);
        event::emit_event<SwapEvent<X, Y>>(
            &mut pair_event_holder.swap,
            SwapEvent<X, Y> {
                user: sender_addr,
                amount_x_in,
                amount_y_in,
                amount_x_out,
                amount_y_out
            }
        );
    }

    public(friend) fun add_swap_event_with_address<X, Y>(
        sender_addr: address,
        amount_x_in: u64,
        amount_y_in: u64,
        amount_x_out: u64,
        amount_y_out: u64
    ) acquires PairEventHolder {
        let pair_event_holder = borrow_global_mut<PairEventHolder<X, Y>>(RESOURCE_ACCOUNT);
        event::emit_event<SwapEvent<X, Y>>(
            &mut pair_event_holder.swap,
            SwapEvent<X, Y> {
                user: sender_addr,
                amount_x_in,
                amount_y_in,
                amount_x_out,
                amount_y_out
            }
        );
    }

    /// Add more liquidity to token types. This method explicitly assumes the
    /// min of both tokens are 0.
    fun add_liquidity_direct<X, Y>(
        x: coin::Coin<X>,
        y: coin::Coin<Y>,
    ): (u64, u64, coin::Coin<LPToken<X, Y>>, coin::Coin<X>, coin::Coin<Y>) acquires TokenPairReserve, TokenPairMetadata {
        let amount_x = coin::value(&x);
        let amount_y = coin::value(&y);
        let (reserve_x, reserve_y, _) = token_reserves<X, Y>();
        let (a_x, a_y) = if (reserve_x == 0 && reserve_y == 0) {
            (amount_x, amount_y)
        } else {
            let amount_y_optimal = swap_utils::quote(amount_x, reserve_x, reserve_y);
            if (amount_y_optimal <= amount_y) {
                (amount_x, amount_y_optimal)
            } else {
                let amount_x_optimal = swap_utils::quote(amount_y, reserve_y, reserve_x);
                assert!(amount_x_optimal <= amount_x, ERROR_INVALID_AMOUNT);
                (amount_x_optimal, amount_y)
            }
        };

        assert!(a_x <= amount_x, ERROR_INSUFFICIENT_AMOUNT);
        assert!(a_y <= amount_y, ERROR_INSUFFICIENT_AMOUNT);

        let left_x = coin::extract(&mut x, amount_x - a_x);
        let left_y = coin::extract(&mut y, amount_y - a_y);
        deposit_x<X, Y>(x);
        deposit_y<X, Y>(y);
        let (lp) = mint<X, Y>();
        (a_x, a_y, lp, left_x, left_y)
    }

    /// Remove liquidity to token types.
    public(friend) fun remove_liquidity<X, Y>(
        sender: &signer,
        liquidity: u64,
    ): (u64, u64) acquires TokenPairMetadata, TokenPairReserve, PairEventHolder {
        let coins = coin::withdraw<LPToken<X, Y>>(sender, liquidity);
        let (coins_x, coins_y) = remove_liquidity_direct<X, Y>(coins);
        let amount_x = coin::value(&coins_x);
        let amount_y = coin::value(&coins_y);
        check_or_register_coin_store<X>(sender);
        check_or_register_coin_store<Y>(sender);
        let sender_addr = signer::address_of(sender);
        coin::deposit<X>(sender_addr, coins_x);
        coin::deposit<Y>(sender_addr, coins_y);
        // event
        let pair_event_holder = borrow_global_mut<PairEventHolder<X, Y>>(RESOURCE_ACCOUNT);
        event::emit_event<RemoveLiquidityEvent<X, Y>>(
            &mut pair_event_holder.remove_liquidity,
            RemoveLiquidityEvent<X, Y> {
                user: sender_addr,
                amount_x,
                amount_y,
                liquidity,
            }
        );
        (amount_x, amount_y)
    }

    /// Remove liquidity to token types.
    fun remove_liquidity_direct<X, Y>(
        liquidity: coin::Coin<LPToken<X, Y>>,
    ): (coin::Coin<X>, coin::Coin<Y>) acquires TokenPairMetadata, TokenPairReserve {
        burn<X, Y>(liquidity)
    }

    /// Swap X to Y, X is in and Y is out. This method assumes amount_out_min is 0
    public(friend) fun swap_exact_x_to_y<X, Y>(
        sender: &signer,
        amount_in: u64,
        to: address
    ): u64 acquires TokenPairReserve, TokenPairMetadata, TokenPairRewardsPool {
        let coins = coin::withdraw<X>(sender, amount_in);
        let (coins_x_out, coins_y_out) = swap_exact_x_to_y_direct<X, Y>(coins);
        let amount_out = coin::value(&coins_y_out);
        check_or_register_coin_store<Y>(sender);
        coin::destroy_zero(coins_x_out); // or others ways to drop `coins_x_out`
        coin::deposit(to, coins_y_out);
        amount_out
    }

    /// Swap X to Y, X is in and Y is out. This method assumes amount_out_min is 0
    public(friend) fun swap_exact_x_to_y_direct<X, Y>(
        coins_in: coin::Coin<X>
    ): (coin::Coin<X>, coin::Coin<Y>) acquires TokenPairReserve, TokenPairMetadata, TokenPairRewardsPool {
        // Grab token pair metadata
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        let amount_in = coin::value<X>(&coins_in);

        // Calculate extracted fees (treasury, team, rewards)
        let treasury_numerator = (amount_in as u128) * (metadata.treasury_fee);
        let amount_to_treasury = treasury_numerator / 10000u128;

        let team_numerator = (amount_in as u128) * (metadata.team_fee);
        let amount_to_team = team_numerator / 10000u128;

        let rewards_numerator = (amount_in as u128) * (metadata.rewards_fee);
        let amount_to_rewards = rewards_numerator / 10000u128;

        // Deposit into <X> balance
        coin::merge(&mut metadata.balance_x, coins_in);

        let (rin, rout, _) = token_reserves<X, Y>();
        let total_fees = token_fees<X, Y>();

        let amount_out = swap_utils::get_amount_out(amount_in, rin, rout, total_fees);
        let (coins_x_out, coins_y_out) = swap<X, Y>(0, amount_out);

        // Grab token pair metadata
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        // Extract treasury fee <X>
        let treasury_coins = coin::extract(&mut metadata.balance_x, (amount_to_treasury as u64));
        coin::merge(&mut metadata.treasury_balance_x, treasury_coins);

        // Extract team fee <X>
        let team_coins = coin::extract(&mut metadata.balance_x, (amount_to_team as u64));
        coin::merge(&mut metadata.team_balance_x, team_coins);

        // Extract rewards fee <X> to pool
        let rewards_pool = borrow_global_mut<TokenPairRewardsPool<X, Y>>(RESOURCE_ACCOUNT);
        let rewards_coins = coin::extract(&mut metadata.balance_x, (amount_to_rewards as u64));
        coin::merge(&mut rewards_pool.pool_balance_x, rewards_coins);

        // Update reserves
        let reserves = borrow_global_mut<TokenPairReserve<X, Y>>(RESOURCE_ACCOUNT);
        let (balance_x, balance_y) = token_balances<X, Y>();
        update(balance_x, balance_y, reserves);

        assert!(coin::value<X>(&coins_x_out) == 0, ERROR_INSUFFICIENT_OUTPUT_AMOUNT);
        (coins_x_out, coins_y_out)
    }

    public(friend) fun swap_x_to_exact_y<X, Y>(
        sender: &signer,
        amount_in: u64,
        amount_out: u64,
        to: address
    ): u64 acquires TokenPairReserve, TokenPairMetadata, TokenPairRewardsPool {
        let coins_in = coin::withdraw<X>(sender, amount_in);
        let (coins_x_out, coins_y_out) = swap_x_to_exact_y_direct<X, Y>(coins_in, amount_out);
        check_or_register_coin_store<Y>(sender);
        coin::destroy_zero(coins_x_out); // or others ways to drop `coins_x_out`
        coin::deposit(to, coins_y_out);
        amount_in
    }

    public(friend) fun swap_x_to_exact_y_direct<X, Y>(
        coins_in: coin::Coin<X>, amount_out: u64
    ): (coin::Coin<X>, coin::Coin<Y>) acquires TokenPairReserve, TokenPairMetadata, TokenPairRewardsPool {
        // Grab token pair metadata
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        let amount_in = coin::value<X>(&coins_in);

        // Calculate extracted fees (treasury, team, rewards)
        let treasury_numerator = (amount_in as u128) * (metadata.treasury_fee);
        let amount_to_treasury = treasury_numerator / 10000u128;

        let team_numerator = (amount_in as u128) * (metadata.team_fee);
        let amount_to_team = team_numerator / 10000u128;

        let rewards_numerator = (amount_in as u128) * (metadata.rewards_fee);
        let amount_to_rewards = rewards_numerator / 10000u128;

        // Deposit <X>
        coin::merge(&mut metadata.balance_x, coins_in);

        let (coins_x_out, coins_y_out) = swap<X, Y>(0, amount_out);

        // Grab token pair metadata
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        // Extract treasury fee <Y>
        let treasury_coins = coin::extract(&mut metadata.balance_x, (amount_to_treasury as u64));
        coin::merge(&mut metadata.treasury_balance_x, treasury_coins);

        // Extract team fee <Y>
        let team_coins = coin::extract(&mut metadata.balance_x, (amount_to_team as u64));
        coin::merge(&mut metadata.team_balance_x, team_coins);

        // Extract rewards fee <Y> to pool
        let rewards_pool = borrow_global_mut<TokenPairRewardsPool<X, Y>>(RESOURCE_ACCOUNT);
        let rewards_coins = coin::extract(&mut metadata.balance_x, (amount_to_rewards as u64));
        coin::merge(&mut rewards_pool.pool_balance_x, rewards_coins);

        // Update reserves
        let reserves = borrow_global_mut<TokenPairReserve<X, Y>>(RESOURCE_ACCOUNT);
        let (balance_x, balance_y) = token_balances<X, Y>();
        update(balance_x, balance_y, reserves);

        assert!(coin::value<X>(&coins_x_out) == 0, ERROR_INSUFFICIENT_OUTPUT_AMOUNT);
        (coins_x_out, coins_y_out)
    }

    /// Swap Y to X, Y is in and X is out. This method assumes amount_out_min is 0
    public(friend) fun swap_exact_y_to_x<X, Y>(
        sender: &signer,
        amount_in: u64,
        to: address
    ): u64 acquires TokenPairReserve, TokenPairMetadata, TokenPairRewardsPool {
        let coins = coin::withdraw<Y>(sender, amount_in);
        let (coins_x_out, coins_y_out) = swap_exact_y_to_x_direct<X, Y>(coins);
        let amount_out = coin::value<X>(&coins_x_out);
        check_or_register_coin_store<X>(sender);
        coin::deposit(to, coins_x_out);
        coin::destroy_zero(coins_y_out); // or others ways to drop `coins_y_out`
        amount_out
    }

    public(friend) fun swap_y_to_exact_x<X, Y>(
        sender: &signer,
        amount_in: u64,
        amount_out: u64,
        to: address
    ): u64 acquires TokenPairReserve, TokenPairMetadata, TokenPairRewardsPool {
        let coins_in = coin::withdraw<Y>(sender, amount_in);
        let (coins_x_out, coins_y_out) = swap_y_to_exact_x_direct<X, Y>(coins_in, amount_out);
        check_or_register_coin_store<X>(sender);
        coin::deposit(to, coins_x_out);
        coin::destroy_zero(coins_y_out); // or others ways to drop `coins_y_out`
        amount_in
    }

    public(friend) fun swap_y_to_exact_x_direct<X, Y>(
        coins_in: coin::Coin<Y>, amount_out: u64
    ): (coin::Coin<X>, coin::Coin<Y>) acquires TokenPairReserve, TokenPairMetadata, TokenPairRewardsPool {
        // Grab token pair metadata
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        let amount_in = coin::value<Y>(&coins_in);

        // Calculate extracted fees (treasury, team, rewards)
        let treasury_numerator = (amount_in as u128) * (metadata.treasury_fee);
        let amount_to_treasury = treasury_numerator / 10000u128;

        let team_numerator = (amount_in as u128) * (metadata.team_fee);
        let amount_to_team = team_numerator / 10000u128;

        let rewards_numerator = (amount_in as u128) * (metadata.rewards_fee);
        let amount_to_rewards = rewards_numerator / 10000u128;

        // Deposit <Y>
        coin::merge(&mut metadata.balance_y, coins_in);

        let (coins_x_out, coins_y_out) = swap<X, Y>(amount_out, 0);

        // Grab token pair metadata
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        // Extract treasury fee <Y>
        let treasury_coins = coin::extract(&mut metadata.balance_y, (amount_to_treasury as u64));
        coin::merge(&mut metadata.treasury_balance_y, treasury_coins);

        // Extract team fee <Y>
        let team_coins = coin::extract(&mut metadata.balance_y, (amount_to_team as u64));
        coin::merge(&mut metadata.team_balance_y, team_coins);

        // Extract rewards fee <Y> to pool
        let rewards_pool = borrow_global_mut<TokenPairRewardsPool<X, Y>>(RESOURCE_ACCOUNT);
        let rewards_coins = coin::extract(&mut metadata.balance_y, (amount_to_rewards as u64));
        coin::merge(&mut rewards_pool.pool_balance_y, rewards_coins);

        // Update reserves
        let reserves = borrow_global_mut<TokenPairReserve<X, Y>>(RESOURCE_ACCOUNT);
        let (balance_x, balance_y) = token_balances<X, Y>();
        update(balance_x, balance_y, reserves);

        assert!(coin::value<Y>(&coins_y_out) == 0, ERROR_INSUFFICIENT_OUTPUT_AMOUNT);
        (coins_x_out, coins_y_out)
    }

    /// Swap Y to X, Y is in and X is out. This method assumes amount_out_min is 0
    public(friend) fun swap_exact_y_to_x_direct<X, Y>(
        coins_in: coin::Coin<Y>
    ): (coin::Coin<X>, coin::Coin<Y>) acquires TokenPairReserve, TokenPairMetadata, TokenPairRewardsPool {
        // Grab token pair metadata
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        let amount_in = coin::value<Y>(&coins_in);

        // Calculate extracted fees (treasury, team, rewards)
        let treasury_numerator = (amount_in as u128) * (metadata.treasury_fee);
        let amount_to_treasury = treasury_numerator / 10000u128;

        let team_numerator = (amount_in as u128) * (metadata.team_fee);
        let amount_to_team = team_numerator / 10000u128;

        let rewards_numerator = (amount_in as u128) * (metadata.rewards_fee);
        let amount_to_rewards = rewards_numerator / 10000u128;

        // Deposit into <Y> balance
        coin::merge(&mut metadata.balance_y, coins_in);

        let (rout, rin, _) = token_reserves<X, Y>();
        let total_fees = token_fees<X, Y>();

        let amount_out = swap_utils::get_amount_out(amount_in, rin, rout, total_fees);
        let (coins_x_out, coins_y_out) = swap<X, Y>(amount_out, 0);

        // Grab token pair metadata
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        // Extract treasury fee <Y>
        let treasury_coins = coin::extract(&mut metadata.balance_y, (amount_to_treasury as u64));
        coin::merge(&mut metadata.treasury_balance_y, treasury_coins);

        // Extract team fee <Y>
        let team_coins = coin::extract(&mut metadata.balance_y, (amount_to_team as u64));
        coin::merge(&mut metadata.team_balance_y, team_coins);

        // Extract rewards fee <Y> to pool
        let rewards_pool = borrow_global_mut<TokenPairRewardsPool<X, Y>>(RESOURCE_ACCOUNT);
        let rewards_coins = coin::extract(&mut metadata.balance_y, (amount_to_rewards as u64));
        coin::merge(&mut rewards_pool.pool_balance_y, rewards_coins);

        let reserves = borrow_global_mut<TokenPairReserve<X, Y>>(RESOURCE_ACCOUNT);
        let (balance_x, balance_y) = token_balances<X, Y>();
        update(balance_x, balance_y, reserves);

        assert!(coin::value<Y>(&coins_y_out) == 0, ERROR_INSUFFICIENT_OUTPUT_AMOUNT);
        (coins_x_out, coins_y_out)
    }

    fun swap<X, Y>(
        amount_x_out: u64,
        amount_y_out: u64
    ): (coin::Coin<X>, coin::Coin<Y>) acquires TokenPairReserve, TokenPairMetadata {
        assert!(amount_x_out > 0 || amount_y_out > 0, ERROR_INSUFFICIENT_OUTPUT_AMOUNT);

        let reserves = borrow_global_mut<TokenPairReserve<X, Y>>(RESOURCE_ACCOUNT);
        assert!(amount_x_out < reserves.reserve_x && amount_y_out < reserves.reserve_y, ERROR_INSUFFICIENT_LIQUIDITY);

        let total_fees = token_fees<X, Y>();

        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        // Calculate total fees here
        let fee_denominator = total_fees + 20u128;

        let coins_x_out = coin::zero<X>();
        let coins_y_out = coin::zero<Y>();
        if (amount_x_out > 0) coin::merge(&mut coins_x_out, extract_x(amount_x_out, metadata));
        if (amount_y_out > 0) coin::merge(&mut coins_y_out, extract_y(amount_y_out, metadata));
        let (balance_x, balance_y) = token_balances<X, Y>();

        let amount_x_in = if (balance_x > reserves.reserve_x - amount_x_out) {
            balance_x - (reserves.reserve_x - amount_x_out)
        } else { 0 };
        let amount_y_in = if (balance_y > reserves.reserve_y - amount_y_out) {
            balance_y - (reserves.reserve_y - amount_y_out)
        } else { 0 };

        assert!(amount_x_in > 0 || amount_y_in > 0, ERROR_INSUFFICIENT_INPUT_AMOUNT);

        let prec = (PRECISION as u128);
        let balance_x_adjusted = (balance_x as u128) * prec - (amount_x_in as u128) * fee_denominator;
        let balance_y_adjusted = (balance_y as u128) * prec - (amount_y_in as u128) * fee_denominator;
        let reserve_x_adjusted = (reserves.reserve_x as u128) * prec;
        let reserve_y_adjusted = (reserves.reserve_y as u128) * prec;

        // No need to use u256 when balance_x_adjusted * balance_y_adjusted and reserve_x_adjusted * reserve_y_adjusted are less than MAX_U128.
        let compare_result = if(balance_x_adjusted > 0 && reserve_x_adjusted > 0 && MAX_U128 / balance_x_adjusted > balance_y_adjusted && MAX_U128 / reserve_x_adjusted > reserve_y_adjusted){
            balance_x_adjusted * balance_y_adjusted >= reserve_x_adjusted * reserve_y_adjusted
        }else{
            let p = u256::mul_u128(balance_x_adjusted, balance_y_adjusted);
            let k = u256::mul_u128(reserve_x_adjusted, reserve_y_adjusted);
            u256::ge(&p, &k)
        };
        assert!(compare_result, ERROR_K);

        update(balance_x, balance_y, reserves);

        (coins_x_out, coins_y_out)
    }

    /// Mint LP Token.
    /// This low-level function should be called from a contract which performs important safety checks
    fun mint<X, Y>(): (coin::Coin<LPToken<X, Y>>) acquires TokenPairReserve, TokenPairMetadata {
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
        let (balance_x, balance_y) = (coin::value(&metadata.balance_x), coin::value(&metadata.balance_y));
        let reserves = borrow_global_mut<TokenPairReserve<X, Y>>(RESOURCE_ACCOUNT);
        let amount_x = (balance_x as u128) - (reserves.reserve_x as u128);
        let amount_y = (balance_y as u128) - (reserves.reserve_y as u128);

        //let fee_amount = mint_fee<X, Y>(reserves.reserve_x, reserves.reserve_y, metadata);

        //Need to add fee amount which have not been mint.
        let total_supply = total_lp_supply<X, Y>();
        let liquidity = if (total_supply == 0u128) {
            let sqrt = math::sqrt(amount_x * amount_y);
            assert!(sqrt > MINIMUM_LIQUIDITY, ERROR_INSUFFICIENT_LIQUIDITY_MINTED);
            let l = sqrt - MINIMUM_LIQUIDITY;
            // permanently lock the first MINIMUM_LIQUIDITY tokens
            mint_lp_to<X, Y>(RESOURCE_ACCOUNT, (MINIMUM_LIQUIDITY as u64), &metadata.mint_cap);
            l
        } else {
            let liquidity = math::min(amount_x * total_supply / (reserves.reserve_x as u128), amount_y * total_supply / (reserves.reserve_y as u128));
            assert!(liquidity > 0u128, ERROR_INSUFFICIENT_LIQUIDITY_MINTED);
            liquidity
        };


        let lp = mint_lp<X, Y>((liquidity as u64), &metadata.mint_cap);

        update<X, Y>(balance_x, balance_y, reserves);

        metadata.k_last = (reserves.reserve_x as u128) * (reserves.reserve_y as u128);

        (lp)
    }

    fun burn<X, Y>(lp_tokens: coin::Coin<LPToken<X, Y>>): (coin::Coin<X>, coin::Coin<Y>) acquires TokenPairMetadata, TokenPairReserve {
        let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
        let (balance_x, balance_y) = (coin::value(&metadata.balance_x), coin::value(&metadata.balance_y));
        let reserves = borrow_global_mut<TokenPairReserve<X, Y>>(RESOURCE_ACCOUNT);
        let liquidity = coin::value(&lp_tokens);

        //let fee_amount = mint_fee<X, Y>(reserves.reserve_x, reserves.reserve_y, metadata);

        //Need to add fee amount which have not been mint.
        let total_lp_supply = total_lp_supply<X, Y>();
        let amount_x = ((balance_x as u128) * (liquidity as u128) / (total_lp_supply as u128) as u64);
        let amount_y = ((balance_y as u128) * (liquidity as u128) / (total_lp_supply as u128) as u64);
        assert!(amount_x > 0 && amount_y > 0, ERROR_INSUFFICIENT_LIQUIDITY_BURNED);

        coin::burn<LPToken<X, Y>>(lp_tokens, &metadata.burn_cap);

        let w_x = extract_x((amount_x as u64), metadata);
        let w_y = extract_y((amount_y as u64), metadata);

        update(coin::value(&metadata.balance_x), coin::value(&metadata.balance_y), reserves);

        metadata.k_last = (reserves.reserve_x as u128) * (reserves.reserve_y as u128);

        (w_x, w_y)
    }

    fun update<X, Y>(balance_x: u64, balance_y: u64, reserve: &mut TokenPairReserve<X, Y>) {
        let block_timestamp = timestamp::now_seconds();

        reserve.reserve_x = balance_x;
        reserve.reserve_y = balance_y;
        reserve.block_timestamp_last = block_timestamp;
    }

    /// Mint LP Tokens to account
    fun mint_lp_to<X, Y>(
        to: address,
        amount: u64,
        mint_cap: &coin::MintCapability<LPToken<X, Y>>
    ) {
        let coins = coin::mint<LPToken<X, Y>>(amount, mint_cap);
        coin::deposit(to, coins);
    }

    /// Mint LP Tokens to account
    fun mint_lp<X, Y>(amount: u64, mint_cap: &coin::MintCapability<LPToken<X, Y>>): coin::Coin<LPToken<X, Y>> {
        coin::mint<LPToken<X, Y>>(amount, mint_cap)
    }

    fun deposit_x<X, Y>(amount: coin::Coin<X>) acquires TokenPairMetadata {
        let metadata =
            borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
        
        coin::merge(&mut metadata.balance_x, amount);
    }

    fun deposit_y<X, Y>(amount: coin::Coin<Y>) acquires TokenPairMetadata {
        let metadata =
            borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);

        coin::merge(&mut metadata.balance_y, amount);
    }

    /// Extract `amount` from this contract
    fun extract_x<X, Y>(amount: u64, metadata: &mut TokenPairMetadata<X, Y>): coin::Coin<X> {
        assert!(coin::value<X>(&metadata.balance_x) > amount, ERROR_INSUFFICIENT_AMOUNT);
        coin::extract(&mut metadata.balance_x, amount)
    }

    /// Extract `amount` from this contract
    fun extract_y<X, Y>(amount: u64, metadata: &mut TokenPairMetadata<X, Y>): coin::Coin<Y> {
        assert!(coin::value<Y>(&metadata.balance_y) > amount, ERROR_INSUFFICIENT_AMOUNT);
        coin::extract(&mut metadata.balance_y, amount)
    }

    public entry fun set_admin(sender: &signer, new_admin: address) acquires SwapInfo {
        let sender_addr = signer::address_of(sender);
        let swap_info = borrow_global_mut<SwapInfo>(RESOURCE_ACCOUNT);
        assert!(sender_addr == swap_info.admin, ERROR_NOT_ADMIN);
        swap_info.admin = new_admin;
    }

    public entry fun set_fee_to(sender: &signer, new_fee_to: address) acquires SwapInfo {
        let sender_addr = signer::address_of(sender);
        let swap_info = borrow_global_mut<SwapInfo>(RESOURCE_ACCOUNT);
        assert!(sender_addr == swap_info.admin, ERROR_NOT_ADMIN);
        swap_info.fee_to = new_fee_to;
    }

    public entry fun set_treasury_fee<X, Y>(sender: &signer, new_treasury_fee: u128) acquires TokenPairMetadata, SwapInfo {
        assert!(new_treasury_fee <= 10, ERROR_EXCESSIVE_FEE);
        let swap_info = borrow_global_mut<SwapInfo>(RESOURCE_ACCOUNT);

        let sender_addr = signer::address_of(sender);
        assert!(sender_addr == swap_info.admin, ERROR_NOT_ADMIN);

        if (swap_utils::sort_token_type<X, Y>()) {
            let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
            
            // Set new liquidity fee
            metadata.treasury_fee = new_treasury_fee;
        } else {
            let metadata = borrow_global_mut<TokenPairMetadata<Y, X>>(RESOURCE_ACCOUNT);

            // Set new liquidity fee
            metadata.treasury_fee = new_treasury_fee;
        }
    }

    public entry fun set_token_fees<X, Y>(sender: &signer, new_liquidity_fee: u128, new_team_fee: u128, new_rewards_fee: u128) acquires TokenPairMetadata, PairEventHolder {

        let total_fees = new_liquidity_fee + new_team_fee + new_rewards_fee;

        // Make sure total fees do not exceed 15%
        assert!(total_fees <= 1500, ERROR_EXCESSIVE_FEE);

        let sender_addr = signer::address_of(sender);

        if (swap_utils::sort_token_type<X, Y>()) {
            let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
            assert!(sender_addr == metadata.creator, ERROR_NOT_CREATOR);
            
            // Set new fees
            metadata.liquidity_fee = new_liquidity_fee;
            metadata.team_fee = new_team_fee;
            metadata.rewards_fee = new_rewards_fee;

            // event
            let pair_event_holder = borrow_global_mut<PairEventHolder<X, Y>>(RESOURCE_ACCOUNT);
            event::emit_event<FeeChangeEvent<X, Y>>(
                &mut pair_event_holder.change_fee,
                FeeChangeEvent<X, Y> {
                    user: sender_addr,
                    liquidity_fee: new_liquidity_fee,
                    team_fee: new_team_fee,
                    rewards_fee: new_rewards_fee
                }
            );
        } else {
            let metadata = borrow_global_mut<TokenPairMetadata<Y, X>>(RESOURCE_ACCOUNT);
            assert!(sender_addr == metadata.creator, ERROR_NOT_CREATOR);

            // Set new fees
            metadata.liquidity_fee = new_liquidity_fee;
            metadata.team_fee = new_team_fee;
            metadata.rewards_fee = new_rewards_fee;

            // event
            let pair_event_holder = borrow_global_mut<PairEventHolder<Y, X>>(RESOURCE_ACCOUNT);
            event::emit_event<FeeChangeEvent<Y, X>>(
                &mut pair_event_holder.change_fee,
                FeeChangeEvent<Y, X> {
                    user: sender_addr,
                    liquidity_fee: new_liquidity_fee,
                    team_fee: new_team_fee,
                    rewards_fee: new_rewards_fee
                }
            );
        }
    }

    public entry fun withdraw_team_fee<X, Y>(sender: &signer) acquires TokenPairMetadata {
        let sender_addr = signer::address_of(sender);

        if (swap_utils::sort_token_type<X, Y>()) {
            let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
            assert!(sender_addr == metadata.creator, ERROR_NOT_CREATOR);
            
            assert!(coin::value(&metadata.team_balance_x) > 0 || coin::value(&metadata.team_balance_y) > 0, ERROR_NO_FEE_WITHDRAW);

            if (coin::value(&metadata.team_balance_x) > 0) {
                let coin = coin::extract_all(&mut metadata.team_balance_x);
                check_or_register_coin_store<X>(sender);
                coin::deposit(sender_addr, coin);
            };

            if (coin::value(&metadata.team_balance_y) > 0) {
                let coin = coin::extract_all(&mut metadata.team_balance_y);
                check_or_register_coin_store<Y>(sender);
                coin::deposit(sender_addr, coin);
            };
        } else {
            let metadata = borrow_global_mut<TokenPairMetadata<Y, X>>(RESOURCE_ACCOUNT);
            assert!(sender_addr == metadata.creator, ERROR_NOT_CREATOR);

            assert!(coin::value(&metadata.team_balance_x) > 0 || coin::value(&metadata.team_balance_y) > 0, ERROR_NO_FEE_WITHDRAW);

            if (coin::value(&metadata.team_balance_x) > 0) {
                let coin = coin::extract_all(&mut metadata.team_balance_x);
                check_or_register_coin_store<X>(sender);
                coin::deposit(sender_addr, coin);
            };

            if (coin::value(&metadata.team_balance_y) > 0) {
                let coin = coin::extract_all(&mut metadata.team_balance_y);
                check_or_register_coin_store<Y>(sender);
                coin::deposit(sender_addr, coin);
            };
        }
    }

    public entry fun withdraw_fee<X, Y>(sender: &signer) acquires SwapInfo, TokenPairMetadata {
        let sender_addr = signer::address_of(sender);
        let swap_info = borrow_global<SwapInfo>(RESOURCE_ACCOUNT);
        assert!(sender_addr == swap_info.fee_to, ERROR_NOT_FEE_TO);

        if (swap_utils::sort_token_type<X, Y>()) {
            let metadata = borrow_global_mut<TokenPairMetadata<X, Y>>(RESOURCE_ACCOUNT);
            assert!(coin::value(&metadata.treasury_balance_x) > 0 || coin::value(&metadata.treasury_balance_y) > 0, ERROR_NO_FEE_WITHDRAW);

            if (coin::value(&metadata.treasury_balance_x) > 0) {
                let coin = coin::extract_all(&mut metadata.treasury_balance_x);
                check_or_register_coin_store<X>(sender);
                coin::deposit(sender_addr, coin);
            };

            if (coin::value(&metadata.treasury_balance_y) > 0) {
                let coin = coin::extract_all(&mut metadata.treasury_balance_y);
                check_or_register_coin_store<Y>(sender);
                coin::deposit(sender_addr, coin);
            };
        } else {
            let metadata = borrow_global_mut<TokenPairMetadata<Y, X>>(RESOURCE_ACCOUNT);
            assert!(coin::value(&metadata.treasury_balance_x) > 0 || coin::value(&metadata.treasury_balance_y) > 0, ERROR_NO_FEE_WITHDRAW);
            if (coin::value(&metadata.treasury_balance_x) > 0) {
                let coin = coin::extract_all(&mut metadata.treasury_balance_x);
                check_or_register_coin_store<X>(sender);
                coin::deposit(sender_addr, coin);
            };

            if (coin::value(&metadata.treasury_balance_y) > 0) {
                let coin = coin::extract_all(&mut metadata.treasury_balance_y);
                check_or_register_coin_store<Y>(sender);
                coin::deposit(sender_addr, coin);
            };
        };
    }

    public entry fun upgrade_swap(sender: &signer, metadata_serialized: vector<u8>, code: vector<vector<u8>>) acquires SwapInfo {
        let sender_addr = signer::address_of(sender);
        let swap_info = borrow_global<SwapInfo>(RESOURCE_ACCOUNT);
        assert!(sender_addr == swap_info.admin, ERROR_NOT_ADMIN);
        let resource_signer = account::create_signer_with_capability(&swap_info.signer_cap);
        code::publish_package_txn(&resource_signer, metadata_serialized, code);
    }

    #[test_only]
    public fun initialize(sender: &signer) {
        init_module(sender);
    }
}
