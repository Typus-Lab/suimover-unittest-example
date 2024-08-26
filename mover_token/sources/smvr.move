module mover_token::smvr {
    use sui::coin::{Self, TreasuryCap};
    use sui::url;

    // ======== Structs =========
    public struct Registry has key{
        id: UID,
        treasury_cap: TreasuryCap<SMVR>
    }

    public struct SMVR has drop {}

    #[lint_allow(share_owned)] // ignore sharing owned object
    fun init(witness: SMVR, ctx: &mut TxContext) {
        let (treasury_cap, coin_metadata) = coin::create_currency(
            witness,
            8,
            b"MVR",
            b"Sui Mover Token",
            b"Fake Suimover token on Sui",
            option::some(url::new_unsafe_from_bytes(b"https://raw.githubusercontent.com/Typus-Lab/suimover-unittest-example/main/mover_token/SMVR.svg")),
            ctx
        );

        let registry =  Registry {
            id: object::new(ctx),
            treasury_cap
        };

        transfer::public_share_object(coin_metadata);
        transfer::share_object(registry);
    }
}