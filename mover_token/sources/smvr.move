module mover_token::smvr {
    use sui::balance::Balance;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
    use sui::dynamic_field;
    use sui::sui::SUI;
    use std::type_name::{Self, TypeName};
    use sui::url;

    use mover_token::pool::{Self, Pool};

    const C_MAX_SUPPLY: u64 = 666_666_666_666_666_666;

    const E_EXCEED_MAX_SUPPLY: u64 = 0;

    public struct SmvrManager has key, store {
        id: UID
    }

    // ======== Structs =========
    public struct Registry has key{
        id: UID,
        treasury_cap: TreasuryCap<SMVR>,
        coin_metadata: CoinMetadata<SMVR>
    }

    public struct SMVR has drop {}

    // #[lint_allow(share_owned)] // ignore sharing owned object
    fun init(witness: SMVR, ctx: &mut TxContext) {
        let (treasury_cap, coin_metadata) = coin::create_currency(
            witness,
            9,
            b"SMVR",
            b"Sui Mover Token",
            b"Fake Sui Mover token on Sui",
            option::some(url::new_unsafe_from_bytes(b"https://raw.githubusercontent.com/Typus-Lab/suimover-unittest-example/main/mover_token/SMVR.svg")),
            ctx
        );

        let registry =  Registry {
            id: object::new(ctx),
            treasury_cap,
            coin_metadata
        };

        let manager = SmvrManager {
            id: object::new(ctx),
        };

        transfer::public_transfer(manager, tx_context::sender(ctx));
        transfer::share_object(registry);
    }

    // ======= Manager functions =======
    public fun mint(
        _manager: &SmvrManager,
        registry: &mut Registry,
        mint_amount: u64,
        ctx: &mut TxContext,
    ): Coin<SMVR> {
        let total_supply = coin::total_supply(&registry.treasury_cap);
        assert!(mint_amount <= C_MAX_SUPPLY - total_supply, E_EXCEED_MAX_SUPPLY);
        coin::mint(&mut registry.treasury_cap, mint_amount, ctx)
    }

    public fun burn(
        _manager: &SmvrManager,
        registry: &mut Registry,
        smvr_coin: Coin<SMVR>,
    ): u64 {
        coin::burn(&mut registry.treasury_cap, smvr_coin)
    }

    entry fun issue_manager_for_user(
        _manager: &SmvrManager,
        user: address,
        ctx: &mut TxContext
    ) {
        let manager = SmvrManager {
            id: object::new(ctx),
        };
        transfer::public_transfer(manager, user);
    }

    entry fun update_icon_url(
        _manager: &SmvrManager,
        registry: &mut Registry,
        url: vector<u8>,
    ) {
        let url = std::ascii::string(url);
        coin::update_icon_url(&registry.treasury_cap, &mut registry.coin_metadata, url);
    }

    entry fun mint_and_stake(
        registry: &mut Registry,
        pool: &mut Pool,
        sui_coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sui_coin_value = sui_coin.value();
        let smvr_amount = sui_coin_value / 100;
        let total_supply = coin::total_supply(&registry.treasury_cap);
        assert!(smvr_amount <= C_MAX_SUPPLY - total_supply, E_EXCEED_MAX_SUPPLY);
        let smvr_coin = coin::mint(&mut registry.treasury_cap, smvr_amount, ctx);
        pool::stake<SMVR>(pool, smvr_coin, clock, ctx);
        store_coin<SUI>(registry, sui_coin);
    }

    fun store_coin<TOKEN>(
        registry: &mut Registry,
        coin: Coin<TOKEN>
    ) {
        let token_type = type_name::get<TOKEN>();
        let balance = coin.into_balance();
        if (dynamic_field::exists_<TypeName>(&registry.id, token_type)) {
            let pool_balance = dynamic_field::borrow_mut<TypeName, Balance<TOKEN>>(&mut registry.id, token_type);
            pool_balance.join(balance);
        } else {
            dynamic_field::add(&mut registry.id, token_type, balance);
        };
    }

    // Exercise 1:
    // Is bug existed in function mint_and_stake? Definitely! Please test it and fix it!
    // Exercise 2:
    // Please add a feature that an user can unstake from pool and burn each SMVR for 100 SUI
    // Also, create test functions to test if it works!
}