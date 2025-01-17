#[test_only]
module nft_protocol::test_utils {
    use sui::object::UID;

    struct Foo has key, store {
        id: UID,
    }

    struct Witness has drop {}

    public fun witness(): Witness {
        Witness {}
    }

    // TODO: This will be reintroduced
    // public fun create_collection_and_allowlist(
    //     creator: address,
    //     scenario: &mut Scenario,
    // ): (ID, ID, ID) {
    //     let delegated_witness = witness::from_witness(Witness {});

    //     let collection: Collection<Foo> = collection::create(
    //         delegated_witness, ctx(scenario),
    //     );

    //     let mint_cap = mint_cap::new_unlimited(
    //         delegated_witness, &collection, ctx(scenario),
    //     );

    //     let col_id = object::id(&collection);
    //     let cap_id = object::id(&mint_cap);

    //     public_share_object(collection);
    //     test_scenario::next_tx(scenario, creator);

    //     transfer_allowlist::init_allowlist(&Witness {}, ctx(scenario));

    //     test_scenario::next_tx(scenario, creator);

    //     let wl: Allowlist = test_scenario::take_shared(scenario);
    //     let wl_id = object::id(&wl);

    //     transfer_allowlist::insert_collection<Foo, Witness>(
    //         &mut wl,
    //         &Witness {},
    //         witness::from_witness<Foo, Witness>(Witness {}),
    //     );

    //     public_transfer(mint_cap, creator);
    //     test_scenario::return_shared(wl);

    //     (col_id, cap_id, wl_id)
    // }
}
