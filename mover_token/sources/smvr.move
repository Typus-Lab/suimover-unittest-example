module mover_token::smvr {
    use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
    use sui::url;

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

    // Exercise:
    // Please add a feature that an user can use 100 SUI to mint 1 SMVR, or burn 1 SMVR for 100 SUI
    // Also, create test functions to test if it works!
}