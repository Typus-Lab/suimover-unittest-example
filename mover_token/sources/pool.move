module mover_token::pool {
    use std::type_name::{Self, TypeName};
    use std::string::{Self, String};

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::dynamic_field;
    use sui::table::{Self, Table};
    use sui::vec_map::{Self, VecMap};
    use sui::event::emit;

    // ======== Constants ========
    const C_INCENTIVE_INDEX_DECIMAL: u64 = 9;

    // ======== Keys ========
    const K_LP_USER_SHARES: vector<u8> = b"lp_user_shares";

    // ======== Errors ========
    const E_TOKEN_TYPE_MISMATCHED: u64 = 0;
    const E_USER_SHARE_NOT_EXISTED: u64 = 1;
    const E_USER_SHARE_NOT_YET_EXPIRED: u64 = 2;
    const E_USER_MISMATCHED: u64 = 3;
    const E_ACTIVE_SHARES_NOT_ENOUGH: u64 = 4;
    const E_ZERO_UNLOCK_COUNTDOWN: u64 = 5;
    const E_ALREADY_DEACTIVATED: u64 = 6;
    const E_ALREADY_ACTIVATED: u64 = 7;
    const E_ZERO_INCENTIVE: u64 = 9;
    const E_ZERO_PERIOD_INCENTIVE_AMOUNT: u64 = 10;
    const E_ZERO_COIN: u64 = 11;

    public struct PoolManager has key, store {
        id: UID
    }

    public struct Pool has key, store {
        id: UID,
        pool_info: PoolInfo,
        config: PoolConfig,
        incentives: vector<Incentive>,
    }

    public struct Incentive has store {
        id: UID,
        token_type: TypeName,
        config: IncentiveConfig,
        info: IncentiveInfo
    }

    public struct PoolInfo has copy, drop, store {
        stake_token: TypeName,
        total_share: u64, // = total staked and has not been unsubscribed
        active: bool,
        next_incentive_id: u64,
    }

    public struct PoolConfig has copy, drop, store {
        unlock_countdown_ts_ms: u64,
    }

    public struct IncentiveConfig has copy, drop, store {
        period_incentive_amount: u64,
        incentive_interval_ts_ms: u64,
    }

    public struct IncentiveInfo has copy, drop, store {
        incentive_id: u64,
        active: bool,
        last_allocate_ts_ms: u64, // record allocate ts ms for each I_TOKEN
        incentive_price_index: u64, // price index for accumulating incentive
    }

    public struct LpUserShare has store {
        user: address,
        stake_ts_ms: u64,
        total_shares: u64,
        active_shares: u64,
        deactivating_shares: vector<DeactivatingShares>,
        last_incentive_price_index: VecMap<u64, u64>, // incentive_id, index_value
    }

    public struct DeactivatingShares has store {
        shares: u64,
        unsubscribed_ts_ms: u64,
        unlocked_ts_ms: u64,
        unsubscribed_incentive_price_index: VecMap<u64, u64>, // the share can only receive incentive until this index
    }

    fun init(ctx: &mut TxContext) {
        let manager = PoolManager {
            id: object::new(ctx),
        };
        transfer::public_transfer(manager, tx_context::sender(ctx));
    }

    public struct NewPoolEvent has copy, drop {
        sender: address,
        pool_info: PoolInfo,
        pool_config: PoolConfig,
    }
    entry fun new_pool<TOKEN>(
        _manager: &PoolManager,
        unlock_countdown_ts_ms: u64,
        ctx: &mut TxContext
    ) {
        // safety check
        assert!(unlock_countdown_ts_ms > 0, E_ZERO_UNLOCK_COUNTDOWN);

        let mut id = object::new(ctx);

        // field for TOKEN balance
        let stake_token = type_name::get<TOKEN>();
        dynamic_field::add(&mut id, stake_token, balance::zero<TOKEN>());

        // field for user share
        dynamic_field::add(&mut id, string::utf8(K_LP_USER_SHARES), table::new<address, LpUserShare>(ctx));

        // object field for Pool
        let pool = Pool {
            id,
            pool_info: PoolInfo {
                stake_token,
                total_share: 0,
                active: true,
                next_incentive_id: 0
            },
            config: PoolConfig {
                unlock_countdown_ts_ms,
            },
            incentives: vector::empty(),
        };

        emit(NewPoolEvent {
            sender: tx_context::sender(ctx),
            pool_info: pool.pool_info,
            pool_config: pool.config,
        });

        transfer::share_object(pool);
    }

    public struct CreateIncentiveProgramEvent has copy, drop {
        pool_address: address,
        incentive_token: TypeName,
        incentive_info: IncentiveInfo,
        incentive_config: IncentiveConfig,
    }
    entry fun create_incentive_program<I_TOKEN>(
        _manager: &PoolManager,
        pool: &mut Pool,
        // incentive config
        incentive: Coin<I_TOKEN>,
        period_incentive_amount: u64,
        incentive_interval_ts_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(incentive.value() > 0, E_ZERO_INCENTIVE);
        assert!(period_incentive_amount > 0, E_ZERO_PERIOD_INCENTIVE_AMOUNT);
        // create public struct Incentive
        let incentive_token = type_name::get<I_TOKEN>();
        let mut incentive_program = Incentive {
            id: object::new(ctx),
            token_type: incentive_token,
            config: IncentiveConfig {
                period_incentive_amount,
                incentive_interval_ts_ms,
            },
            info: IncentiveInfo {
                incentive_id: pool.pool_info.next_incentive_id,
                active: true,
                last_allocate_ts_ms: clock::timestamp_ms(clock),
                incentive_price_index: 0,
            }
        };

        emit(CreateIncentiveProgramEvent {
            pool_address: object::id_address(pool),
            incentive_token: incentive_program.token_type,
            incentive_info: incentive_program.info,
            incentive_config: incentive_program.config,
        });

        dynamic_field::add(&mut incentive_program.id, incentive_token, incentive.into_balance());
        vector::push_back(&mut pool.incentives, incentive_program);
        pool.pool_info.next_incentive_id = pool.pool_info.next_incentive_id + 1;
    }

    public struct DeactivateIncentiveProgramEvent has copy, drop {
        pool_address: address,
        sender: address,
        incentive_program_idx: u64,
        incentive_token: TypeName,
    }
    entry fun deactivate_incentive_program<I_TOKEN>(
        _manager: &PoolManager,
        pool: &mut Pool,
        incentive_program_idx: u64,
        ctx: &TxContext
    ) {
        // safety check
        let incentive_token = type_name::get<I_TOKEN>();
        let incentive = &mut pool.incentives[incentive_program_idx];
        assert!(incentive.token_type == incentive_token, E_TOKEN_TYPE_MISMATCHED);
        assert!(incentive.info.active, E_ALREADY_DEACTIVATED);

        incentive.info.active = false;

        emit(DeactivateIncentiveProgramEvent {
            pool_address: object::id_address(pool),
            sender: tx_context::sender(ctx),
            incentive_program_idx,
            incentive_token,
        });
    }

    public struct ActivateIncentiveTokenEvent has copy, drop {
        pool_address: address,
        incentive_program_idx: u64,
        incentive_token: TypeName,
    }
    entry fun activate_incentive_token<I_TOKEN>(
        _manager: &PoolManager,
        pool: &mut Pool,
        incentive_program_idx: u64,
    ) {
        // safety check
        let incentive_token = type_name::get<I_TOKEN>();
        let incentive = &mut pool.incentives[incentive_program_idx];
        assert!(incentive.token_type == incentive_token, E_TOKEN_TYPE_MISMATCHED);
        assert!(!incentive.info.active, E_ALREADY_ACTIVATED);

        incentive.info.active = true;

        emit(ActivateIncentiveTokenEvent {
            pool_address: object::id_address(pool),
            incentive_program_idx,
            incentive_token,
        });
    }

    public struct RemoveIncentiveProgramEvent has copy, drop {
        pool_address: address,
        incentive_program_idx: u64,
        incentive_token: TypeName,
        incentive_balance_value: u64,
    }
    public fun remove_incentive_program<I_TOKEN>(
        _manager: &PoolManager,
        pool: &mut Pool,
        incentive_program_idx: u64,
        ctx: &mut TxContext
    ): Coin<I_TOKEN> {
        // safety check
        let incentive_token = type_name::get<I_TOKEN>();
        let incentive = pool.incentives.remove(incentive_program_idx);
        assert!(incentive.token_type == incentive_token, E_TOKEN_TYPE_MISMATCHED);

        let Incentive {
            mut id,
            token_type: _,
            config: _,
            info: _
        } = incentive;

        let incentive_balance: Balance<I_TOKEN> = dynamic_field::remove(&mut id, incentive_token);
        object::delete(id);

        emit(RemoveIncentiveProgramEvent {
            pool_address: object::id_address(pool),
            incentive_program_idx,
            incentive_token,
            incentive_balance_value: balance::value(&incentive_balance),
        });

        coin::from_balance(incentive_balance, ctx)
    }

    public struct UpdateUnlockCountdownTsMsEvent has copy, drop {
        pool_address: address,
        previous_unlock_countdown_ts_ms: u64,
        new_unlock_countdown_ts_ms: u64,
    }
    entry fun update_unlock_countdown_ts_ms(
        _manager: &PoolManager,
        pool: &mut Pool,
        unlock_countdown_ts_ms: u64,
    ) {
        // safety check
        assert!(unlock_countdown_ts_ms > 0, E_ZERO_UNLOCK_COUNTDOWN);

        let previous_unlock_countdown_ts_ms = pool.config.unlock_countdown_ts_ms;
        pool.config.unlock_countdown_ts_ms = unlock_countdown_ts_ms;

        emit(UpdateUnlockCountdownTsMsEvent {
            pool_address: object::id_address(pool),
            previous_unlock_countdown_ts_ms,
            new_unlock_countdown_ts_ms: unlock_countdown_ts_ms,
        });
    }

    public struct UpdateIncentiveConfigEvent has copy, drop {
        pool_address: address,
        previous_incentive_config: IncentiveConfig,
        new_incentive_config: IncentiveConfig,
    }
    entry fun update_incentive_config(
        _manager: &PoolManager,
        pool: &mut Pool,
        // incentive config
        incentive_program_idx: u64,
        mut period_incentive_amount: Option<u64>,
        mut incentive_interval_ts_ms: Option<u64>,
    ) {
        let pool_address = object::id_address(pool);
        // safety check
        let incentive = &mut pool.incentives[incentive_program_idx];

        let previous_incentive_config = incentive.config;

        if (option::is_some(&period_incentive_amount)) {
            incentive.config.period_incentive_amount = option::extract(&mut period_incentive_amount);
        };
        if (option::is_some(&incentive_interval_ts_ms)) {
            incentive.config.incentive_interval_ts_ms = option::extract(&mut incentive_interval_ts_ms);
        };
        emit(UpdateIncentiveConfigEvent {
            pool_address,
            previous_incentive_config,
            new_incentive_config: incentive.config,
        });
    }

    public(package) fun allocate_incentive(
        pool: &mut Pool,
        clock: &Clock,
    ) {
        // safety check
        let mut i = 0;
        let length = vector::length(&pool.incentives);
        while (i < length) {
            let incentive = vector::borrow_mut(&mut pool.incentives, i);

            // only update incentive index for active incentive tokens
            if (incentive.info.active) {
                let last_allocate_ts_ms = incentive.info.last_allocate_ts_ms;

                // clip current_ts_ms into interval increment
                let mut current_ts_ms = clock::timestamp_ms(clock);
                current_ts_ms = current_ts_ms / incentive.config.incentive_interval_ts_ms * incentive.config.incentive_interval_ts_ms;

                // allocate latest incentive into incentive_price_index
                if (current_ts_ms > last_allocate_ts_ms) {
                    let period_allocate_amount = ((incentive.config.period_incentive_amount as u128)
                        * ((current_ts_ms - last_allocate_ts_ms) as u128)
                            / (incentive.config.incentive_interval_ts_ms as u128) as u64);
                    let price_index_increment = if (pool.pool_info.total_share > 0) {
                        ((multiplier(C_INCENTIVE_INDEX_DECIMAL) as u128)
                            * (period_allocate_amount as u128)
                                / (pool.pool_info.total_share as u128) as u64)
                    } else { 0 };

                    incentive.info.incentive_price_index = incentive.info.incentive_price_index + price_index_increment;
                    incentive.info.last_allocate_ts_ms = current_ts_ms;
                };
            };
            i = i + 1;
        };
    }

    public struct StakeEvent has copy, drop {
        pool_address: address,
        token_type: TypeName,
        stake_amount: u64,
        stake_ts_ms: u64,
        last_incentive_price_index: VecMap<u64, u64>,
    }
    public fun stake<TOKEN>(
        pool: &mut Pool,
        stake_token: Coin<TOKEN>,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        // safety check
        let user = tx_context::sender(ctx);
        let token_type = type_name::get<TOKEN>();
        assert!(token_type == pool.pool_info.stake_token, E_TOKEN_TYPE_MISMATCHED);
        assert!(stake_token.value() > 0, E_ZERO_COIN);

        allocate_incentive(pool, clock);

        // join balance
        let balance = stake_token.into_balance();
        let balance_value = balance::value(&balance);
        balance::join(dynamic_field::borrow_mut(&mut pool.id, token_type), balance);

        // create LpUserShare
        let current_ts_ms = clock::timestamp_ms(clock);
        let user_existed = {
            let all_lp_user_shares
                = dynamic_field::borrow<String, Table<address, LpUserShare>>(&pool.id, string::utf8(K_LP_USER_SHARES));
            all_lp_user_shares.contains(user)
        };
        let lp_user_share = if (user_existed) {
            let mut lp_user_share
                = remove_user_share(&mut pool.id, tx_context::sender(ctx));
            assert!(user == lp_user_share.user, E_USER_MISMATCHED);

            lp_user_share.stake_ts_ms = current_ts_ms;
            lp_user_share.total_shares = lp_user_share.total_shares + balance_value;
            lp_user_share.active_shares = lp_user_share.active_shares + balance_value;
            lp_user_share.last_incentive_price_index = get_last_incentive_price_index(pool);
            lp_user_share
        } else {
            let lp_user_share = LpUserShare {
                user,
                stake_ts_ms: current_ts_ms,
                total_shares: balance_value,
                active_shares: balance_value,
                deactivating_shares: vector::empty(),
                last_incentive_price_index: get_last_incentive_price_index(pool),
            };
            lp_user_share
        };

        emit(StakeEvent {
            pool_address: object::id_address(pool),
            token_type,
            stake_amount: lp_user_share.total_shares,
            stake_ts_ms: lp_user_share.stake_ts_ms,
            last_incentive_price_index: lp_user_share.last_incentive_price_index,
        });

        store_user_shares(&mut pool.id, user, lp_user_share);
        pool.pool_info.total_share = pool.pool_info.total_share + balance_value;
    }

    public struct UnsubscribeEvent has copy, drop {
        pool_address: address,
        token_type: TypeName,
        unsubscribed_shares: u64,
        unsubscribe_ts_ms: u64,
        unlocked_ts_ms: u64,
    }
    public fun unsubscribe<TOKEN>(
        pool: &mut Pool,
        mut unsubscribed_shares: Option<u64>,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        // safety check
        let token_type = type_name::get<TOKEN>();
        assert!(token_type == pool.pool_info.stake_token, E_TOKEN_TYPE_MISMATCHED);

        allocate_incentive(pool, clock);

        let current_ts_ms = clock::timestamp_ms(clock);
        let last_incentive_price_index = get_last_incentive_price_index(pool);
        let user = tx_context::sender(ctx);
        let mut lp_user_share = remove_user_share(&mut pool.id, user);
        let unsubscribed_shares = if (unsubscribed_shares.is_some()) {
            unsubscribed_shares.extract()
        } else {
            lp_user_share.active_shares
        };
        assert!(lp_user_share.active_shares >= unsubscribed_shares, E_ACTIVE_SHARES_NOT_ENOUGH);

        lp_user_share.active_shares = lp_user_share.active_shares - unsubscribed_shares;

        let unlocked_ts_ms = current_ts_ms + pool.config.unlock_countdown_ts_ms;

        let deactivating_shares = DeactivatingShares {
            shares: unsubscribed_shares,
            unsubscribed_ts_ms: current_ts_ms,
            unlocked_ts_ms,
            unsubscribed_incentive_price_index: last_incentive_price_index,
        };
        lp_user_share.deactivating_shares.push_back(deactivating_shares);
        store_user_shares(&mut pool.id, lp_user_share.user, lp_user_share);
        pool.pool_info.total_share = pool.pool_info.total_share - unsubscribed_shares;
        emit(UnsubscribeEvent {
            pool_address: object::id_address(pool),
            token_type,
            unsubscribed_shares,
            unsubscribe_ts_ms: current_ts_ms,
            unlocked_ts_ms,
        });
    }

    public struct UnstakeEvent has copy, drop {
        pool_address: address,
        token_type: TypeName,
        unstake_amount: u64,
        unstake_ts_ms: u64,
        u64_padding: vector<u64>
    }
    public fun unstake<TOKEN>(
        pool: &mut Pool,
        mut unstaked_shares: Option<u64>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<TOKEN> {
        // safety check
        let token_type = type_name::get<TOKEN>();
        assert!(token_type == pool.pool_info.stake_token, E_TOKEN_TYPE_MISMATCHED);

        allocate_incentive(pool, clock);

        let current_ts_ms = clock::timestamp_ms(clock);
        let mut lp_user_share = remove_user_share(&mut pool.id, tx_context::sender(ctx));
        let unstaked_shares = if (unstaked_shares.is_some()) {
            unstaked_shares.extract()
        } else {
            lp_user_share.total_shares - lp_user_share.active_shares
        };

        let mut i = 0;
        let length = lp_user_share.deactivating_shares.length();
        let mut temp_unstaked_shares = 0;
        while (i < length) {
            if (temp_unstaked_shares == unstaked_shares) {
                break
            };

            let deactivating_shares = lp_user_share.deactivating_shares.borrow(0);

            assert!(deactivating_shares.unlocked_ts_ms <= current_ts_ms, E_USER_SHARE_NOT_YET_EXPIRED);

            if (unstaked_shares >= temp_unstaked_shares + deactivating_shares.shares) {
                let DeactivatingShares {
                    shares,
                    unsubscribed_ts_ms: _,
                    unlocked_ts_ms: _,
                    unsubscribed_incentive_price_index: _,
                } = lp_user_share.deactivating_shares.remove(0);
                temp_unstaked_shares = temp_unstaked_shares + shares;
            } else {
                let unstaked = unstaked_shares - temp_unstaked_shares;
                temp_unstaked_shares = temp_unstaked_shares + unstaked;
                let deactivating_shares = lp_user_share.deactivating_shares.borrow_mut(0);
                deactivating_shares.shares = deactivating_shares.shares - unstaked;
            };

            i = i + 1;
        };

        lp_user_share.total_shares = lp_user_share.total_shares - temp_unstaked_shares;

        if (
            lp_user_share.deactivating_shares.length() == 0
            && lp_user_share.total_shares == 0
            && lp_user_share.active_shares == 0
        ) {
            let LpUserShare {
                user: _,
                stake_ts_ms: _,
                total_shares: _,
                active_shares: _,
                deactivating_shares,
                last_incentive_price_index: _,
            } = lp_user_share;
            deactivating_shares.destroy_empty();
        } else {
            store_user_shares(&mut pool.id, lp_user_share.user, lp_user_share);
        };

        emit(UnstakeEvent {
            pool_address: object::id_address(pool),
            token_type,
            unstake_amount: temp_unstaked_shares,
            unstake_ts_ms: current_ts_ms,
            u64_padding: vector::empty()
        });

        let b = balance::split(dynamic_field::borrow_mut(&mut pool.id, token_type), temp_unstaked_shares);
        coin::from_balance(b, ctx)
    }

    public struct HarvestEvent has copy, drop {
        pool_address: address,
        incentive_token_type: TypeName,
        harvest_amount: u64,
    }
    public fun harvest<I_TOKEN>(
        pool: &mut Pool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<I_TOKEN> {
        // safety check
        let user = tx_context::sender(ctx);
        let incentive_token = type_name::get<I_TOKEN>();

        allocate_incentive(pool, clock);

        let mut lp_user_share = remove_user_share(&mut pool.id, user);
        let mut balance = balance::zero<I_TOKEN>();
        let length = pool.incentives.length();
        let mut i = 0;
        while (i < length) {
            let (current_incentive_token, incentive_id) = (pool.incentives[i].token_type, pool.incentives[i].info.incentive_id);
            if (current_incentive_token == incentive_token) {
                let (current_incentive_value, current_incentive_index)
                    = calculate_incentive(pool, incentive_id, &lp_user_share);

                if (lp_user_share.last_incentive_price_index.contains(&incentive_id)) {
                    let last_incentive_price_index = lp_user_share.last_incentive_price_index.get_mut(&incentive_id);
                    *last_incentive_price_index = current_incentive_index;
                } else {
                    lp_user_share.last_incentive_price_index.insert(incentive_id, current_incentive_index);
                };

                let incentive_pool_value = dynamic_field::borrow<TypeName, Balance<I_TOKEN>>(&pool.incentives[i].id, incentive_token).value();
                let current_incentive_value = if (current_incentive_value > incentive_pool_value) {
                    incentive_pool_value
                } else { current_incentive_value };
                balance.join(
                    dynamic_field::borrow_mut<TypeName, Balance<I_TOKEN>>(&mut pool.incentives[i].id, incentive_token).split(current_incentive_value)
                );
            };
            i = i + 1;
        };

        emit(HarvestEvent {
            pool_address: object::id_address(pool),
            incentive_token_type: incentive_token,
            harvest_amount: balance.value(),
        });

        store_user_shares(&mut pool.id, user, lp_user_share);

        coin::from_balance(balance, ctx)
    }

    // ======= Inner Functions =======
    fun store_user_shares(id: &mut UID, user: address, user_shares: LpUserShare) {
        let all_lp_user_shares = dynamic_field::borrow_mut<String, Table<address, LpUserShare>>(id, string::utf8(K_LP_USER_SHARES));
        table::add<address, LpUserShare>(all_lp_user_shares, user, user_shares);
    }

    fun remove_user_share(id: &mut UID, user: address): LpUserShare {
        let all_lp_user_shares = dynamic_field::borrow_mut<String, Table<address, LpUserShare>>(id, string::utf8(K_LP_USER_SHARES));

        assert!(all_lp_user_shares.contains(user), E_USER_SHARE_NOT_EXISTED);

        all_lp_user_shares.remove(user)
    }

    fun calculate_incentive(
        pool: &Pool,
        incentive_id: u64,
        lp_user_share: &LpUserShare,
    ): (u64, u64) {
        let incentive = &pool.incentives[incentive_id];
        let current_incentive_index = incentive.info.incentive_price_index;
        let lp_last_incentive_price_index = if (
            lp_user_share.last_incentive_price_index.contains(&incentive_id)
        ) {
            *lp_user_share.last_incentive_price_index.get(&incentive_id)
        } else {
            // not in lp_user_share.last_incentive_price_index
            // => new incentive token set after staking / harvesting => new index should be always start from 0
            0
        };

        let mut incentive_value = 0;

        // incentive_value from active shares
        let d_incentive_index = current_incentive_index - lp_last_incentive_price_index;
        incentive_value = incentive_value + ((lp_user_share.active_shares as u128)
                            * (d_incentive_index as u128)
                                / (multiplier(C_INCENTIVE_INDEX_DECIMAL) as u128) as u64);

        // incentive_value from deactivating shares
        let mut i = 0;
        let length = lp_user_share.deactivating_shares.length();
        while (i < length) {
            let deactivating_shares = &lp_user_share.deactivating_shares[i];
            // unsubscribed_incentive_price_index was initially set when unsubscribing
            // incentive_token not existed in unsubscribed_incentive_price_index => pool incentive_token set after unlocking
            // => deactivating_shares has no right to attend to this incentive token
            if (deactivating_shares.unsubscribed_incentive_price_index.contains(&incentive_id)) {
                let unsubscribed_incentive_price_index
                    = *deactivating_shares.unsubscribed_incentive_price_index.get(&incentive_id);
                // if lp_last_incentive_price_index >= unsubscribed_incentive_price_index
                // => no more incentive for this deactivating share
                let d_incentive_index = if (unsubscribed_incentive_price_index > lp_last_incentive_price_index) {
                    unsubscribed_incentive_price_index - lp_last_incentive_price_index
                } else { 0 };
                incentive_value = incentive_value + ((deactivating_shares.shares as u128)
                                    * (d_incentive_index as u128)
                                        / (multiplier(C_INCENTIVE_INDEX_DECIMAL) as u128) as u64);
            };
            i = i + 1;
        };

        (incentive_value, current_incentive_index)
    }

    // ======= Helper Functions =======
    public(package) fun get_incentive_tokens(pool: &Pool): vector<TypeName> {
        let mut i = 0;
        let length = vector::length(&pool.incentives);
        let mut incentive_tokens = vector::empty();
        while (i < length) {
            vector::push_back(
                &mut incentive_tokens,
                vector::borrow(&pool.incentives, i).token_type
            );
            i = i + 1;
        };
        incentive_tokens
    }

    public(package) fun get_last_incentive_price_index(pool: &Pool): VecMap<u64, u64> {
        let incentives = &pool.incentives;
        let length = incentives.length();
        let mut last_incentive_price_index = vec_map::empty();
        let mut i = 0;
        while (i < length) {
            let incentive = &incentives[i];
            last_incentive_price_index.insert(incentive.info.incentive_id, incentive.info.incentive_price_index);
            i = i + 1;
        };
        last_incentive_price_index
    }

    public(package) fun create_user_last_incentive_ts_ms(pool: &Pool, current_ts_ms: u64): VecMap<u64, u64> {
        let incentives = &pool.incentives;
        let length = incentives.length();
        let mut last_incentive_ts_ms = vec_map::empty();
        let mut i = 0;
        while (i < length) {
            let incentive = &incentives[i];
            last_incentive_ts_ms.insert(incentive.info.incentive_id, current_ts_ms);
            i = i + 1;
        };
        last_incentive_ts_ms
    }

    // for decimals
    public fun multiplier(decimal: u64): u64 {
        let mut i = 0;
        let mut multiplier = 1;
        while (i < decimal) {
            multiplier = multiplier * 10;
            i = i + 1;
        };
        multiplier
    }

    #[test_only]
    public(package) fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

    #[test_only]
    public(package) fun test_get_lp_user_share_info<I_TOKEN>(
        pool: &Pool,
        ctx: &TxContext
    ): (u64, u64, u64, VecMap<u64, u64>) {
        let incentive_token = type_name::get<I_TOKEN>();
        let all_lp_user_shares
            = dynamic_field::borrow<String, Table<address, LpUserShare>>(&pool.id, string::utf8(K_LP_USER_SHARES));
        let user_shares = table::borrow(all_lp_user_shares, tx_context::sender(ctx));

        let mut i = 0;
        let length = pool.incentives.length();
        let mut last_incentive_price_index = vec_map::empty<u64, u64>();
        while (i < length) {
            let incentives = &pool.incentives[i];
            let incentive_id = incentives.info.incentive_id;
            if (incentive_token == incentives.token_type) {
                if (user_shares.last_incentive_price_index.contains(&incentive_id)) {
                    last_incentive_price_index.insert(incentive_id, *user_shares.last_incentive_price_index.get(&incentive_id));
                } else {
                    last_incentive_price_index.insert(incentive_id, 0);
                };
            };
            i = i + 1;
        };
        (user_shares.stake_ts_ms, user_shares.total_shares, user_shares.active_shares, last_incentive_price_index)
    }

    #[test_only]
    public(package) fun test_get_user_deactivating_share(
        pool: &Pool,
        ctx: &TxContext
    ): (vector<u64>, vector<u64>, vector<u64>, vector<VecMap<u64, u64>>) {
        let all_lp_user_shares
            = dynamic_field::borrow<String, Table<address, LpUserShare>>(&pool.id, string::utf8(K_LP_USER_SHARES));
        let user_shares = table::borrow(all_lp_user_shares, tx_context::sender(ctx));

        let mut i = 0;
        let length = user_shares.deactivating_shares.length();
        let mut shares = vector::empty<u64>();
        let mut unsubscribed_ts_ms = vector::empty<u64>();
        let mut unlocked_ts_ms = vector::empty<u64>();
        let mut unsubscribed_incentive_price_index = vector::empty<VecMap<u64, u64>>();
        while (i < length) {
            let deactivating_shares = &user_shares.deactivating_shares[i];
            shares.push_back(deactivating_shares.shares);
            unsubscribed_ts_ms.push_back(deactivating_shares.unsubscribed_ts_ms);
            unlocked_ts_ms.push_back(deactivating_shares.unlocked_ts_ms);
            unsubscribed_incentive_price_index.push_back(deactivating_shares.unsubscribed_incentive_price_index);
            i = i + 1;
        };
        (shares, unsubscribed_ts_ms, unlocked_ts_ms, unsubscribed_incentive_price_index)
    }
}


#[test_only]
module mover_token::test_pool {
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario::{Scenario, begin, end, ctx, next_tx, take_shared, return_shared, take_from_sender, return_to_sender, sender};
    use sui::vec_map::VecMap;

    use mover_token::pool::{Self, Pool, PoolManager};
    use mover_token::smvr::SMVR;

    const ADMIN: address = @0xFFFF;
    const USER_1: address = @0xBABE1;
    const USER_2: address = @0xBABE2;
    const UNLOCK_COUNTDOWN_TS_MS: u64 = 5 * 24 * 60 * 60 * 1000; // 5 days
    const PERIOD_INCENTIVE_AMOUNT: u64 = 0_0100_00000;
    const INCENTIVE_INTERVAL_TS_MS: u64 = 60_000;
    const C_INCENTIVE_INDEX_DECIMAL: u64 = 9;

    const CURRENT_TS_MS: u64 = 1_715_212_800_000;

    fun scenario(): Scenario {
        let mut scenario = begin(ADMIN);
        pool::test_init(ctx(&mut scenario));
        next_tx(&mut scenario, ADMIN);
        scenario
    }

    fun new_clock(scenario: &mut Scenario): Clock {
        let mut clock = clock::create_for_testing(ctx(scenario));
        clock::set_for_testing(&mut clock, CURRENT_TS_MS);
        clock
    }

    fun pool(scenario: &Scenario): Pool {
        take_shared<Pool>(scenario)
    }

    fun pool_manager(scenario: &Scenario): PoolManager {
        take_from_sender<PoolManager>(scenario)
    }

    fun mint_test_coin<T>(scenario: &mut Scenario, amount: u64): Coin<T> {
        coin::mint_for_testing<T>(amount, ctx(scenario))
    }

    fun update_clock(clock: &mut Clock, ts_ms: u64) {
        clock::set_for_testing(clock, ts_ms);
    }

    fun test_new_pool_<TOKEN>(scenario: &mut Scenario, unlock_countdown_ts_ms: u64) {
        let pool_manager = pool_manager(scenario);
        pool::new_pool<TOKEN>(
            &pool_manager,
            unlock_countdown_ts_ms,
            ctx(scenario)
        );
        return_to_sender(scenario, pool_manager);
        next_tx(scenario, ADMIN);
    }

    fun test_create_incentive_program_<I_TOKEN>(scenario: &mut Scenario, incentive_amount: u64) {
        let pool_manager = pool_manager(scenario);
        let mut pool = pool(scenario);
        let clock = new_clock(scenario);
        let coin = mint_test_coin<I_TOKEN>(scenario, incentive_amount);
        pool::create_incentive_program<I_TOKEN>(
            &pool_manager,
            &mut pool,
            // incentive config
            coin,
            PERIOD_INCENTIVE_AMOUNT,
            INCENTIVE_INTERVAL_TS_MS,
            &clock,
            ctx(scenario)
        );
        return_shared(pool);
        return_to_sender(scenario, pool_manager);
        clock::destroy_for_testing(clock);
        next_tx(scenario, ADMIN);
    }

    fun test_stake_<TOKEN>(
        scenario: &mut Scenario,
        stake_amount: u64,
        stake_ts_ms: u64
    ) {
        let mut pool = pool(scenario);
        let stake_token = mint_test_coin<TOKEN>(scenario, stake_amount);
        let mut clock = new_clock(scenario);
        update_clock(&mut clock, stake_ts_ms);
        pool::stake<TOKEN>(
            &mut pool,
            stake_token,
            &clock,
            ctx(scenario)
        );
        return_shared(pool);
        clock::destroy_for_testing(clock);
        next_tx(scenario, ADMIN);
    }

    fun test_unsubscribe_<TOKEN>(scenario: &mut Scenario, mut unsubscribed_shares: Option<u64>, unsubscribe_ts_ms: u64): VecMap<u64, u64> {
        let user = sender(scenario);
        let mut pool = pool(scenario);
        let mut clock = new_clock(scenario);
        update_clock(&mut clock, unsubscribe_ts_ms);

        // not using price index => no matter what TOKEN generic passed for test_get_lp_user_share_info
        let (
            _stake_ts_ms,
            _total_shares,
            active_shares,
            _last_incentive_price_index
        ) = pool::test_get_lp_user_share_info<TOKEN>(&pool, ctx(scenario));
        let unsubscrbed_share = if (unsubscribed_shares.is_none()) {
            active_shares
        } else {
            unsubscribed_shares.extract()
        };

        pool::unsubscribe<TOKEN>(
            &mut pool,
            unsubscribed_shares,
            &clock,
            ctx(scenario),
        );
        next_tx(scenario, user);

        let (
            shares,
            unsubscribed_ts_ms,
            unlocked_ts_ms,
            unsubscribed_incentive_price_index
        ) = pool::test_get_user_deactivating_share(&pool, ctx(scenario));

        // check correct
        assert!(shares[shares.length()-1] == unsubscrbed_share, 0);
        assert!(unsubscribed_ts_ms[unsubscribed_ts_ms.length()-1] == unsubscribe_ts_ms, 0);
        assert!(unlocked_ts_ms[unlocked_ts_ms.length()-1] == unsubscribe_ts_ms + UNLOCK_COUNTDOWN_TS_MS, 0);
        let last_incentive_price_index = pool::get_last_incentive_price_index(&pool);
        let unsubscribed_index = unsubscribed_incentive_price_index[unsubscribed_incentive_price_index.length() - 1];
        let mut keys = unsubscribed_index.keys();
        while (keys.length() > 0) {
            let incentive_id = keys.pop_back();
            assert!(unsubscribed_index.get(&incentive_id) == last_incentive_price_index.get(&incentive_id), 0);
        };

        return_shared(pool);
        clock::destroy_for_testing(clock);
        next_tx(scenario, ADMIN);
        unsubscribed_index
    }

    fun test_unstake_<TOKEN>(scenario: &mut Scenario, unstaked_shares: Option<u64>, unstake_ts_ms: u64): u64 {
        let mut pool = pool(scenario);
        let mut clock = new_clock(scenario);
        update_clock(&mut clock, unstake_ts_ms);

        let unstaked_coin = pool::unstake<TOKEN>(
            &mut pool,
            unstaked_shares,
            &clock,
            ctx(scenario),
        );

        let unstaked_coin_value = unstaked_coin.value();
        transfer::public_transfer(unstaked_coin, sender(scenario));

        return_shared(pool);
        clock::destroy_for_testing(clock);
        next_tx(scenario, ADMIN);
        unstaked_coin_value
    }

    fun test_harvest_<I_TOKEN>(scenario: &mut Scenario, harvest_ts_ms: u64): (u64, VecMap<u64, u64>) {
        let mut pool = pool(scenario);
        let mut clock = new_clock(scenario);
        update_clock(&mut clock, harvest_ts_ms);
        let harvest_balance = pool::harvest<I_TOKEN>(&mut pool, &clock, ctx(scenario));
        let harvest_balance_value = harvest_balance.value();

        let (
            _,
            _,
            _,
            last_incentive_price_index
        ) = pool::test_get_lp_user_share_info<I_TOKEN>(&pool, ctx(scenario));
        // get stake pool get_last_incentive_price_index
        let incentive_price_indices
            = pool::get_last_incentive_price_index(&pool);

        let mut incentive_ids = last_incentive_price_index.keys();
        while (incentive_ids.length() > 0) {
            let incentive_id = incentive_ids.pop_back();
            let index_from_user = last_incentive_price_index.get(&incentive_id);
            let index_from_pool = incentive_price_indices.get(&incentive_id);
            assert!(index_from_user == index_from_pool, 0);
        };

        transfer::public_transfer(harvest_balance, sender(scenario));
        return_shared(pool);
        clock::destroy_for_testing(clock);
        next_tx(scenario, ADMIN);
        (harvest_balance_value, incentive_price_indices)
    }

    #[test]
    public(package) fun test_new_pool() {
        let mut scenario = scenario();
        test_new_pool_<SMVR>(&mut scenario, UNLOCK_COUNTDOWN_TS_MS);
        end(scenario);
    }

    #[test]
    public(package) fun test_create_incentive_program() {
        let mut scenario = scenario();
        test_new_pool_<SMVR>(&mut scenario, UNLOCK_COUNTDOWN_TS_MS);
        test_create_incentive_program_<SUI>(&mut scenario, PERIOD_INCENTIVE_AMOUNT);
        test_create_incentive_program_<SUI>(&mut scenario, PERIOD_INCENTIVE_AMOUNT * 2);
        end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = pool::E_ZERO_INCENTIVE)]
    public(package) fun test_invalid_incentive_program() {
        let mut scenario = scenario();
        test_new_pool_<SMVR>(&mut scenario, UNLOCK_COUNTDOWN_TS_MS);
        test_create_incentive_program_<SUI>(&mut scenario, 0);
        end(scenario);
    }

    #[test]
    public(package) fun test_stake() {
        let mut scenario = scenario();
        test_new_pool_<SMVR>(&mut scenario, UNLOCK_COUNTDOWN_TS_MS);

        let incentive_amount = 1000_0000_00000;
        test_create_incentive_program_<SUI>(&mut scenario, incentive_amount);

        let stake_amount = 1_0000_00000;
        test_stake_<SMVR>(&mut scenario, stake_amount, CURRENT_TS_MS);
        end(scenario);
    }


    #[test]
    #[expected_failure(abort_code = pool::E_USER_SHARE_NOT_YET_EXPIRED)]
    public(package) fun test_early_unstake_failed() {
        let mut scenario = scenario();
        test_new_pool_<SMVR>(&mut scenario, UNLOCK_COUNTDOWN_TS_MS);

        let incentive_amount = 1000_0000_00000;
        test_create_incentive_program_<SUI>(&mut scenario, incentive_amount);

        next_tx(&mut scenario, USER_1);
        let stake_amount = 1_0000_00000;
        test_stake_<SMVR>(&mut scenario, stake_amount, CURRENT_TS_MS);

        // USER_1 unsubscribes immediately after staking
        next_tx(&mut scenario, USER_1);
        let unsubscribes_ts_ms_1 = CURRENT_TS_MS;
        let _unsubscribed_indices = test_unsubscribe_<SMVR>(&mut scenario, option::none(), unsubscribes_ts_ms_1);

        next_tx(&mut scenario, USER_1);
        let unstake_ts_ms = CURRENT_TS_MS + INCENTIVE_INTERVAL_TS_MS; // < unlock time
        let _ = test_unstake_<SMVR>(&mut scenario, option::none(), unstake_ts_ms); // unstake all

        end(scenario);
    }

    #[test]
    public(package) fun test_unstake_multiple_times() {
        let mut scenario = scenario();
        test_new_pool_<SMVR>(&mut scenario, UNLOCK_COUNTDOWN_TS_MS);

        let incentive_amount = 1000_0000_00000;
        test_create_incentive_program_<SUI>(&mut scenario, incentive_amount);

        next_tx(&mut scenario, USER_1);
        let stake_amount_1 = 1_0000_00000;
        test_stake_<SMVR>(&mut scenario, stake_amount_1, CURRENT_TS_MS);

        next_tx(&mut scenario, USER_2);
        let stake_amount_2 = 0_0100_00000;
        test_stake_<SMVR>(&mut scenario, stake_amount_2, CURRENT_TS_MS);

        next_tx(&mut scenario, USER_2);
        let stake_amount_3 = 0_3000_00000;
        test_stake_<SMVR>(&mut scenario, stake_amount_3, CURRENT_TS_MS + 1);

        // USER_2 unsubscribes immediately after staking
        next_tx(&mut scenario, USER_2);
        let unsubscribes_ts_ms_1 = CURRENT_TS_MS + 1;
        let _unsubscribed_indices = test_unsubscribe_<SMVR>(&mut scenario, option::none(), unsubscribes_ts_ms_1);

        next_tx(&mut scenario, USER_1);
        let stake_amount_4 = 1_0000_00000;
        test_stake_<SMVR>(
            &mut scenario,
            stake_amount_4,
            CURRENT_TS_MS + INCENTIVE_INTERVAL_TS_MS
        ); // stake at first incentive period

        // USER_1 unsubscribes immediately after staking
        next_tx(&mut scenario, USER_1);
        let unsubscribes_ts_ms_2 = CURRENT_TS_MS + INCENTIVE_INTERVAL_TS_MS;
        let _unsubscribed_indices = test_unsubscribe_<SMVR>(&mut scenario, option::none(), unsubscribes_ts_ms_2);

        // USER_1 unstake 1
        next_tx(&mut scenario, USER_1);
        let unstake_ts_ms_1 = unsubscribes_ts_ms_2 + UNLOCK_COUNTDOWN_TS_MS;
        let unstake_amount_1 = 1;
        let return_amount_1
            = test_unstake_<SMVR>(&mut scenario, option::some(unstake_amount_1), unstake_ts_ms_1);
        assert!(return_amount_1 == unstake_amount_1, 1);

        // unstake USER_2 all shares
        next_tx(&mut scenario, USER_2);
        let unstake_ts_ms_2 = unsubscribes_ts_ms_1 + UNLOCK_COUNTDOWN_TS_MS;
        let return_amount_2 = test_unstake_<SMVR>(&mut scenario, option::none(), unstake_ts_ms_2);
        assert!(return_amount_2 == stake_amount_2 + stake_amount_3, 2);

        // unstake USER_1 all shares
        next_tx(&mut scenario, USER_1);
        let unstake_ts_ms_3 = unstake_ts_ms_1 + UNLOCK_COUNTDOWN_TS_MS;
        let return_amount_3
            = test_unstake_<SMVR>(&mut scenario, option::none(), unstake_ts_ms_3);
        assert!(return_amount_3 == stake_amount_1 + stake_amount_4 - unstake_amount_1, 3);

        end(scenario);
    }

    #[test]
    public(package) fun test_normal_harvest() {
        let mut scenario = scenario();
        test_new_pool_<SMVR>(&mut scenario, UNLOCK_COUNTDOWN_TS_MS);

        let incentive_amount = 1000_0000_00000;
        test_create_incentive_program_<SUI>(&mut scenario, incentive_amount);

        // USER_1 stakes 1_0000_00000
        next_tx(&mut scenario, USER_1);
        let stake_amount_1 = 1_0000_00000;
        test_stake_<SMVR>(&mut scenario, stake_amount_1, CURRENT_TS_MS);

        // USER_1 harvest within locked-up period
        next_tx(&mut scenario, USER_1);
        let harvest_ts_ms_0 = CURRENT_TS_MS + INCENTIVE_INTERVAL_TS_MS;
        let (harvest_balance_value, incentive_price_index_1) = test_harvest_<SUI>(&mut scenario, harvest_ts_ms_0);
        let mut estimated_value_1 = 0;
        let mut keys = incentive_price_index_1.keys();
        while (keys.length() > 0) {
            let key = keys.pop_back();
            let incentive_price_index = incentive_price_index_1.get(&key);
            let estimated_value = ((stake_amount_1 as u128)
                * (*incentive_price_index as u128)
                    / (pool::multiplier(C_INCENTIVE_INDEX_DECIMAL) as u128) as u64);
            estimated_value_1 = estimated_value_1 + estimated_value;
        };
        assert!(harvest_balance_value == estimated_value_1, 0);
        end(scenario);
    }

    #[test]
    public(package) fun test_complex_harvest() {
        let mut scenario = scenario();
        test_new_pool_<SMVR>(&mut scenario, UNLOCK_COUNTDOWN_TS_MS);

        let incentive_amount = 1000_0000_00000;
        test_create_incentive_program_<SUI>(&mut scenario, incentive_amount);

        // USER_1 stakes 1_0000_00000
        next_tx(&mut scenario, USER_1);
        let stake_amount_1 = 1_0000_00000;
        test_stake_<SMVR>(&mut scenario, stake_amount_1, CURRENT_TS_MS);

        // USER_2 stakes 0_0100_00000
        next_tx(&mut scenario, USER_2);
        let stake_amount_2 = 0_0100_00000;
        test_stake_<SMVR>(&mut scenario, stake_amount_2, CURRENT_TS_MS);

        // USER_1 harvest within locked-up period
        next_tx(&mut scenario, USER_1);
        let harvest_ts_ms_0 = CURRENT_TS_MS + INCENTIVE_INTERVAL_TS_MS;
        let (harvest_balance_value, incentive_price_index_1) = test_harvest_<SUI>(&mut scenario, harvest_ts_ms_0);
        let mut estimated_value_1 = 0;
        let mut keys = incentive_price_index_1.keys();
        while (keys.length() > 0) {
            let key = keys.pop_back();
            let incentive_price_index = incentive_price_index_1.get(&key);
            let estimated_value = ((stake_amount_1 as u128)
                * (*incentive_price_index as u128)
                    / (pool::multiplier(C_INCENTIVE_INDEX_DECIMAL) as u128) as u64);
            estimated_value_1 = estimated_value_1 + estimated_value;
        };
        assert!(harvest_balance_value == estimated_value_1, 0);

        // USER_2 harvest within locked-up period
        next_tx(&mut scenario, USER_2);
        let harvest_ts_ms_1 = CURRENT_TS_MS + INCENTIVE_INTERVAL_TS_MS + 1; // which means it would be the same period as USER_1
        let (harvest_balance_value, incentive_price_index_2) = test_harvest_<SUI>(&mut scenario, harvest_ts_ms_1);
        let mut estimated_value_2 = 0;
        let mut keys = incentive_price_index_2.keys();
        while (keys.length() > 0) {
            let key = keys.pop_back();
            let incentive_price_index = incentive_price_index_2.get(&key);
            let incentive_price_index_from_1 = incentive_price_index_1.get(&key);
            let estimated_value = ((stake_amount_2 as u128)
                * (*incentive_price_index as u128)
                    / (pool::multiplier(C_INCENTIVE_INDEX_DECIMAL) as u128) as u64);
            estimated_value_2 = estimated_value_2 + estimated_value;
            assert!(incentive_price_index_from_1 == incentive_price_index, 0);
        };
        assert!(harvest_balance_value == estimated_value_2, 0);

        // USER_1 harvest within locked-up period
        next_tx(&mut scenario, USER_1);
        let harvest_ts_ms_2 = CURRENT_TS_MS + 5 * INCENTIVE_INTERVAL_TS_MS;
        let (harvest_balance_value, incentive_price_index_3) = test_harvest_<SUI>(&mut scenario, harvest_ts_ms_2);
        let mut estimated_value_3 = 0;
        let mut keys = incentive_price_index_3.keys();
        while (keys.length() > 0) {
            let key = keys.pop_back();
            let incentive_price_index = incentive_price_index_3.get(&key);
            let last_incentive_price_index = incentive_price_index_1.get(&key);
            let estimated_value = ((stake_amount_1 as u128)
                * ((*incentive_price_index - *last_incentive_price_index) as u128)
                    / (pool::multiplier(C_INCENTIVE_INDEX_DECIMAL) as u128) as u64);
            estimated_value_3 = estimated_value_3 + estimated_value;
        };
        assert!(harvest_balance_value == estimated_value_3, 0);

        // USER_1 unsubscribes all shares @ last harvest time + 1 INCENTIVE_INTERVAL_TS_MS
        next_tx(&mut scenario, USER_1);
        let unsubscribes_ts_ms_1 = harvest_ts_ms_2 + INCENTIVE_INTERVAL_TS_MS;
        let unsubscribed_indices = test_unsubscribe_<SMVR>(&mut scenario, option::none(), unsubscribes_ts_ms_1);

        // USER_1 harvest accross expiration
        next_tx(&mut scenario, USER_1);
        let expiration_ts_ms = unsubscribes_ts_ms_1 + UNLOCK_COUNTDOWN_TS_MS;
        let harvest_ts_ms_3 = expiration_ts_ms + 5 * INCENTIVE_INTERVAL_TS_MS;
        let (harvest_balance_value, _incentive_price_index_4) = test_harvest_<SUI>(&mut scenario, harvest_ts_ms_3);
        let mut estimated_value_4 = 0;
        let mut keys = incentive_price_index_3.keys();
        while (keys.length() > 0) {
            let incentive_id = keys.pop_back();
            let last_incentive_price_index = incentive_price_index_3.get(&incentive_id);
            let unsubscribed_index = unsubscribed_indices.get(&incentive_id);
            let estimated_value = ((stake_amount_1 as u128)
                * ((*unsubscribed_index - *last_incentive_price_index) as u128)
                    / (pool::multiplier(C_INCENTIVE_INDEX_DECIMAL) as u128) as u64);
            estimated_value_4 = estimated_value_4 + estimated_value;
        };
        assert!(harvest_balance_value == estimated_value_4, 0);

        // USER_1 harvest after expiration
        next_tx(&mut scenario, USER_1);
        let harvest_ts_ms_4 = harvest_ts_ms_3 + 3 * INCENTIVE_INTERVAL_TS_MS;
        let (harvest_balance_value, _incentive_price_index_5) = test_harvest_<SUI>(&mut scenario, harvest_ts_ms_4);
        assert!(harvest_balance_value == 0, 0);

        end(scenario);
    }

    // Exercise 1:
    // Please test this case: USER_1 stakes zero coin.

    // Exercise 2:
    // Please test if USER_1 harvest twice in the same clock time. Is it allowed to return reward with zero amount?

    // Exercise 3:
    // Design a function called "restake" to allow an user to move his deactivating shares back into active part.
    // And design tests:
    // (1) normal restake case
    // (2) restake zero share
    // (3) an user without holding deactivating shares to call restake

    // Exercise 4:
    // Does the mechanism of incentive allocation code match what we would like to do during designing?
    // Design more scenarios to test the interaction among units

    // Exercise 5:
    // If you create two SUI incentive programs, does it still work well?
}