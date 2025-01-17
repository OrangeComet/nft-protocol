/// Quorum is a primitive for regulating access management to administrative
/// objects such `MintCap`, `Publisher`, `LaunchpadCap` among others.
///
/// The core problem that Quorum tries to solve is that it's not sufficiently
/// secure to own Capability objects directly via a keypair. Owning Cap objects
/// directly equates to centralization risk, exposing projects to
/// the risk that such keypair gets compromised.
///
/// Quorum solves this by providing a flexible yet ergonomic way of regulating
/// access control over these objects. Baseline Multi-sig only solves the
/// problem of distributing the risk accross keypairs but it does not provide an
/// ergonomic on-chain abstraction with ability to manage access control as well
/// as delegation capatibilities.
///
/// The core mechanics of the Quorum are the following:
///
/// 1. Allowed users can borrow Cap objects from the Quorum but have to return
/// it in the same batch of programmable transactions. When authorised users
/// call `borrow_cap` they will receive the Cap object `T` and a hot potato object
/// `ReturnReceipt<F, T>`. In order for the batch of transactions to suceed this
/// hot potato object needs to be returned in conjunctions with the Cap `T`.
///
/// 2. Quorum exports two users types: Admins and Members. Any `Admin` user can
/// add or remove `Member` users. To add or remove `Admin` users, at least >50%
/// of the admins need to vote in favor. (Note: This is the baseline
/// functionality that the quorum provides but it can be overwritten by
/// Quorum extensions to fit specific needs of projects)
///
/// 3. Only Admins can insert Cap objects to Quorums. When inserting Cap objects,
/// admins can decide if these are accessible to Admin-only or if they are also
/// accessible to Members.
///
/// 4. Delegation: To facilitate interactivity between parties, such as Games
/// or NFT creators and Marketplaces, Quorums can delegate access rights to other
/// Quorums. This means that sophisticated creators can create a CreatoQuorum and
/// delegate access rights to a MarketplaceQuorum. This allows for creators to
/// preserve their sovereignty over the collection's affairs, whilst allowing for
/// Marketplaces or other Third-Parties to act on their behalf.
///
/// 5. Simplicity: The above case is an advanced option, however creators can
/// decide to start simple by calling quorum::singleton(creator_address), which
/// effectively mimics as if the creator would own the Cap objects directly.
///
/// Another option for simplicity, in cases where creators are completely
/// abstracted away from the on-chain code, these Cap objects can be stored
/// directly in the marketplace's Quorums. If needed at any time the Marketplace
/// can return the Caps back to the creator address or quorum.
///
/// 6. Extendability: Following our principles of OriginByte as a developer
/// framework, this Quorum can be extended with custom-made implementations.
/// In a nutshell, extensions can:
///
/// - Implement different voting mechanisms with their own majority
/// and minority rules;
/// - Implement different access-permission schemes (they can bypass
/// the Admin-Member model and add their own model)
module nft_protocol::quorum {
    // TODO: Function for poping_caps with vote
    // TODO: Generalise voting
    use std::type_name::{Self, TypeName};
    use std::option;

    use sui::event;
    use sui::math;
    use sui::transfer;
    use sui::vec_set::{Self, VecSet};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::dynamic_field as df;

    use nft_protocol::mint_cap::MintCap;

    const ENOT_AN_ADMIN: u64 = 1;
    const ENOT_A_MEMBER: u64 = 2;
    const ENOT_AN_ADMIN_NOR_MEMBER: u64 = 3;
    const EMIN_ADMIN_COUNT_IS_ONE: u64 = 4;
    const EADDRESS_IS_NOT_ADMIN: u64 = 5;
    const EQUORUM_EXTENSION_MISMATCH: u64 = 6;
    const EINVALID_DELEGATE: u64 = 7;

    struct Quorum<phantom F> has key, store {
        id: UID,
        // TODO: Ideally move to TableSet
        admins: VecSet<address>,
        members: VecSet<address>,
        // TODO: quorum delegates
        delegates: VecSet<ID>,
        admin_count: u64
    }

    struct ReturnReceipt<phantom F, phantom T: key> {}

    struct ExtensionToken<phantom F> has store {
        quorum_id: ID,
    }

    struct Signatures<phantom F> has store, copy, drop {
        // TODO: make this TableSet
        list: VecSet<address>,
    }

    // === Dynamic Field keys ===

    struct AdminField has store, copy, drop {
        type_name: TypeName,
    }

    struct MemberField has store, copy, drop {
        type_name: TypeName,
    }

    struct AddAdmin has store, copy, drop {
        admin: address,
    }

    struct RemoveAdmin has store, copy, drop {
        admin: address,
    }

    struct AddDelegate has store, copy, drop {
        entity: ID,
    }

    struct RemoveDelegate has store, copy, drop {
        entity: ID,
    }

    // === Events ===

    struct CreateQuorumEvent has copy, drop {
        quorum_id: ID,
        type_name: TypeName,
    }

    // === Init Functions ===

    public fun create<F>(
        _witness: &F,
        admins: VecSet<address>,
        members: VecSet<address>,
        delegates: VecSet<ID>,
        ctx: &mut TxContext,
    ): Quorum<F> {
        let id = object::new(ctx);

        event::emit(CreateQuorumEvent {
            quorum_id: object::uid_to_inner(&id),
            type_name: type_name::get<F>(),
        });

        let admin_count = vec_set::size(&admins);

        Quorum { id, admins, members, delegates, admin_count }
    }

    public fun create_for_extension<F>(
        witness: &F,
        admins: VecSet<address>,
        members: VecSet<address>,
        delegates: VecSet<ID>,
        ctx: &mut TxContext,
    ): (Quorum<F>, ExtensionToken<F>) {
        let quorum = create(witness, admins, members, delegates, ctx);
        let extension_token = ExtensionToken { quorum_id: object::id(&quorum) };

        (quorum, extension_token)
    }

    public fun init_quorum<F>(
        witness: &F,
        admins: VecSet<address>,
        members: VecSet<address>,
        delegates: VecSet<ID>,
        ctx: &mut TxContext,
    ) {
        let quorum = create(witness, admins, members, delegates, ctx);
        transfer::share_object(quorum);
    }

    public fun singleton<F>(
        witness: &F,
        admin: address,
        ctx: &mut TxContext,
    ): Quorum<F> {
        create(
            witness,
            vec_set::singleton(admin),
            vec_set::empty(),
            vec_set::empty(),
            ctx
        )
    }

    // === Admin Functions ===

    public entry fun vote_add_admin<F>(
        quorum: &mut Quorum<F>,
        new_admin: address,
        ctx: &mut TxContext,
    ) {
        let (vote_count, threshold) = vote(quorum, AddAdmin { admin: new_admin}, ctx);

        if (vote_count >= threshold) {
            df::remove<AddAdmin, Signatures<F>>(&mut quorum.id, AddAdmin { admin: new_admin});
            vec_set::insert(&mut quorum.admins, new_admin);
            quorum.admin_count = quorum.admin_count + 1;
        };
    }

    public entry fun vote_remove_admin<F>(
        quorum: &mut Quorum<F>,
        old_admin: address,
        ctx: &mut TxContext,
    ) {
        assert!(quorum.admin_count == 1, EMIN_ADMIN_COUNT_IS_ONE);

        let (vote_count, threshold) = vote(quorum, RemoveAdmin { admin: old_admin}, ctx);

        if (vote_count >= threshold) {
            df::remove<RemoveAdmin, Signatures<F>>(&mut quorum.id, RemoveAdmin { admin: old_admin});
            vec_set::remove(&mut quorum.admins, &old_admin);

            quorum.admin_count = quorum.admin_count - 1;
        };
    }

    public fun add_admin_with_extension<F>(
        quorum: &mut Quorum<F>,
        ext_token: &ExtensionToken<F>,
        new_admin: address,
    ) {
        assert_extension_token(quorum, ext_token);

        vec_set::insert(&mut quorum.admins, new_admin);
        quorum.admin_count = quorum.admin_count + 1;
    }

    public fun remove_admin_with_extension<F>(
        quorum: &mut Quorum<F>,
        ext_token: &ExtensionToken<F>,
        old_admin: address,
    ) {
        assert_extension_token(quorum, ext_token);
        vec_set::remove(&mut quorum.admins, &old_admin);

        quorum.admin_count = quorum.admin_count - 1;
    }

    // === Delegate Functions ===

    public entry fun vote_add_delegate<F>(
        quorum: &mut Quorum<F>,
        entity: ID,
        ctx: &mut TxContext,
    ) {
        let (vote_count, threshold) = vote(quorum, AddDelegate { entity }, ctx);

        if (vote_count >= threshold) {
            df::remove<AddDelegate, Signatures<F>>(&mut quorum.id, AddDelegate { entity });
            vec_set::insert(&mut quorum.delegates, entity);
        };
    }

    public entry fun vote_remove_delegate<F>(
        quorum: &mut Quorum<F>,
        entity: ID,
        ctx: &mut TxContext,
    ) {
        assert!(quorum.admin_count > 1, EMIN_ADMIN_COUNT_IS_ONE);

        let (vote_count, threshold) = vote(quorum, RemoveDelegate { entity }, ctx);

        if (vote_count >= threshold) {
            df::remove<RemoveDelegate, Signatures<F>>(&mut quorum.id, RemoveDelegate { entity });
            vec_set::remove(&mut quorum.delegates, &entity);
        };
    }

    public fun add_delegate_with_extension<F>(
        quorum: &mut Quorum<F>,
        ext_token: &ExtensionToken<F>,
        entity: ID,
    ) {
        assert_extension_token(quorum, ext_token);
        vec_set::insert(&mut quorum.delegates, entity);
    }

    public fun remove_delegate_with_extension<F>(
        quorum: &mut Quorum<F>,
        ext_token: &ExtensionToken<F>,
        entity: ID,
    ) {
        assert_extension_token(quorum, ext_token);
        vec_set::remove(&mut quorum.delegates, &entity);
    }

    public fun vote<F, Field: copy + drop + store>(
        quorum: &mut Quorum<F>,
        field: Field,
        ctx: &mut TxContext,
    ): (u64, u64) {
        assert_admin(quorum, ctx);

        let signatures_exist = df::exists_(
            &mut quorum.id, field
        );

        let vote_count: u64;
        let threshold: u64;

        if (signatures_exist) {
            let sigs = df::borrow_mut(
                &mut quorum.id, field
            );

            sign<F>(sigs, ctx);

            vote_count = vec_set::size(&sigs.list);
            threshold = calc_voting_threshold(quorum.admin_count);

        } else {
            let sig = tx_context::sender(ctx);

            let voting_booth = Signatures<F> {
                list: vec_set::singleton(sig),
            };

            df::add(
                &mut quorum.id, field, voting_booth
            );

            vote_count = 1;
            threshold = calc_voting_threshold(quorum.admin_count);
        };

        (vote_count, threshold)
    }

    // TODO: As it stands this is not safe to be public because
    // it has no admin check
    fun sign<F>(
        sigs: &mut Signatures<F>,
        ctx: &mut TxContext,
    ) {
        vec_set::insert(&mut sigs.list, tx_context::sender(ctx))
    }

    // TODO: allow for extensions to chance the majority rule
    fun calc_voting_threshold(
        admin_count: u64,
    ): u64 {
        let threshold: u64;

        if (admin_count == 1) {
            threshold = 1;
        } else {
            threshold = math::divide_and_round_up(admin_count, 2);

            if (admin_count % 2 == 0) {
                threshold = threshold + 1;
            }
        };

        threshold
    }

    public fun add_member<F>(
        quorum: &mut Quorum<F>,
        member: address,
        ctx: &mut TxContext,
    ) {
        assert_admin<F>(quorum, ctx);
        vec_set::insert(&mut quorum.members, member);
    }

    public fun remove_member<F>(
        quorum: &mut Quorum<F>,
        member: address,
        ctx: &mut TxContext,
    ) {
        assert_admin<F>(quorum, ctx);
        vec_set::remove(&mut quorum.members, &member);
    }

    // === MintCap Helper Functions ===

    // TODO: Does it make sense to provide specific functions for MintCap?
    // Or shall we stick to only the generics?

    public fun insert_mint_cap<F, C>(
        quorum: &mut Quorum<F>,
        mint_cap: MintCap<C>,
        admin_only: bool,
        ctx: &mut TxContext,
    ) {
        insert_cap(quorum, mint_cap, admin_only, ctx);
    }

    public fun borrow_mint_cap<F, C>(
        quorum: &mut Quorum<F>,
        ctx: &mut TxContext,
    ): (MintCap<C>, ReturnReceipt<F, MintCap<C>>) {
        borrow_cap(quorum, ctx)
    }

    public fun return_mint_cap<F, C>(
        quorum: &mut Quorum<F>,
        mint_cap: MintCap<C>,
        receipt: ReturnReceipt<F, MintCap<C>>,
        ctx: &mut TxContext,
    ) {
        return_cap(quorum, mint_cap, receipt, ctx)
    }

    // === Object Functions ===

    public fun insert_cap<F, T: key + store>(
        quorum: &mut Quorum<F>,
        cap_object: T,
        admin_only: bool,
        ctx: &mut TxContext,
    ) {
        assert_admin<F>(quorum, ctx);
        insert_cap_(quorum, cap_object, admin_only);
    }

    public fun borrow_cap<F, T: key + store>(
        quorum: &mut Quorum<F>,
        ctx: &mut TxContext,
    ): (T, ReturnReceipt<F, T>) {
        assert_member_or_admin(quorum, ctx);
        let is_admin_field = df::exists_(
            &mut quorum.id, AdminField {type_name: type_name::get<T>()}
        );

        let cap: T;

        if (is_admin_field) {
            assert_admin(quorum, ctx);

            let field = df::borrow_mut(
                &mut quorum.id, AdminField {type_name: type_name::get<T>()}
            );

            cap = option::extract(field);

        } else {
            assert_member(quorum, ctx);

            // Fails if Member field does not exist either
            let field = df::borrow_mut(
                &mut quorum.id, MemberField {type_name: type_name::get<T>()}
            );

            cap = option::extract(field);
        };

        (cap, ReturnReceipt {})
    }

    public fun return_cap<F, T: key + store>(
        quorum: &mut Quorum<F>,
        cap_object: T,
        receipt: ReturnReceipt<F, T>,
        ctx: &mut TxContext,
    ) {
        return_cap_(quorum, cap_object, ctx);
        burn_receipt(receipt);
    }

    public fun borrow_cap_as_delegate<F1, F2, T: key + store>(
        quorum: &mut Quorum<F1>,
        delegate: &Quorum<F2>,
        ctx: &mut TxContext,
    ): (T, ReturnReceipt<F1, T>) {
        assert_delegate(quorum, &delegate.id);
        assert_member_or_admin(delegate, ctx);

        let is_admin_field = df::exists_(
            &mut quorum.id, AdminField {type_name: type_name::get<T>()}
        );

        let cap: T;

        if (is_admin_field) {
            assert_admin(delegate, ctx);

            let field = df::borrow_mut(
                &mut quorum.id, AdminField {type_name: type_name::get<T>()}
            );

            cap = option::extract(field);

        } else {
            assert_member(delegate, ctx);

            // Fails if Member field does not exist either
            let field = df::borrow_mut(
                &mut quorum.id, MemberField {type_name: type_name::get<T>()}
            );

            cap = option::extract(field);
        };

        (cap, ReturnReceipt {})
    }

    public fun return_cap_as_delegate<F1, F2, T: key + store>(
        quorum: &mut Quorum<F1>,
        delegate: &Quorum<F2>,
        cap_object: T,
        receipt: ReturnReceipt<F1, T>,
        ctx: &mut TxContext,
    ) {
        assert_delegate(quorum, &delegate.id);
        assert_member_or_admin(delegate, ctx);

        let is_admin_field = df::exists_(
            &mut quorum.id, AdminField {type_name: type_name::get<T>()}
        );

        if (is_admin_field) {
            assert_admin(delegate, ctx);

            let field = df::borrow_mut(
                &mut quorum.id, AdminField {type_name: type_name::get<T>()}
            );

            option::fill(field, cap_object);
        } else {
            assert_member(delegate, ctx);

            // Fails if Member field does not exist either
            let field = df::borrow_mut(
                &mut quorum.id, MemberField {type_name: type_name::get<T>()}
            );

            option::fill(field, cap_object);
        };

        burn_receipt(receipt);
    }

    fun return_cap_<F, T: key + store>(
        quorum: &mut Quorum<F>,
        cap_object: T,
        ctx: &mut TxContext,
    ) {
        let is_admin_field = df::exists_(
            &mut quorum.id, AdminField {type_name: type_name::get<T>()}
        );

        if (is_admin_field) {
            assert_admin(quorum, ctx);

            let field = df::borrow_mut(
                &mut quorum.id, AdminField {type_name: type_name::get<T>()}
            );

            option::fill(field, cap_object);
        } else {
            assert_member(quorum, ctx);

            // Fails if Member field does not exist either
            let field = df::borrow_mut(
                &mut quorum.id, MemberField {type_name: type_name::get<T>()}
            );

            option::fill(field, cap_object);
        }
    }

    fun insert_cap_<F, T: key + store>(
        quorum: &mut Quorum<F>,
        cap_object: T,
        admin_only: bool,
    ) {
        if (admin_only) {
            df::add(
                &mut quorum.id,
                AdminField {type_name: type_name::get<T>()},
                option::some(cap_object),
            );
        } else {
            df::add(
                &mut quorum.id,
                MemberField {type_name: type_name::get<T>()},
                option::some(cap_object),
            );
        }
    }

    fun burn_receipt<F, T: key + store>(
        receipt: ReturnReceipt<F, T>
    ) {
        ReturnReceipt {} = receipt;
    }

    fun uid_mut<F>(
        quorum: &mut Quorum<F>,
        ext_token: &ExtensionToken<F>,
    ): &mut UID {
        assert_extension_token(quorum, ext_token);

        &mut quorum.id
    }

    public fun assert_admin<F>(quorum: &Quorum<F>, ctx: &TxContext) {
        assert!(vec_set::contains(&quorum.admins, &tx_context::sender(ctx)), ENOT_AN_ADMIN);
    }

    public fun assert_member<F>(quorum: &Quorum<F>, ctx: &TxContext) {
        assert!(vec_set::contains(&quorum.members, &tx_context::sender(ctx)), ENOT_A_MEMBER);
    }

    public fun assert_member_or_admin<F>(quorum: &Quorum<F>, ctx: &TxContext) {
        assert!(
            vec_set::contains(&quorum.admins, &tx_context::sender(ctx))
                || vec_set::contains(&quorum.members, &tx_context::sender(ctx)),
            ENOT_AN_ADMIN_NOR_MEMBER);
    }

    public fun assert_extension_token<F>(quorum: &Quorum<F>, ext_token: &ExtensionToken<F>) {
        assert!(object::id(quorum) == ext_token.quorum_id, EQUORUM_EXTENSION_MISMATCH);
    }

    public fun assert_delegate<F1>(quorum: &Quorum<F1>, delegate_uid: &UID) {
        assert!(
            vec_set::contains(&quorum.delegates, object::uid_as_inner(delegate_uid)),
            EINVALID_DELEGATE
        );
    }
}
