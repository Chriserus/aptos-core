/// An example marketplace for token objects that supports
/// * Highest bidder auctions
/// * Instant buy transfers
/// * Early ending of auctions
/// * Adjustable bid fees, listing fees, and commission
/// * Royalties
/// * Events on listings
///
/// The main philosphy behind this marketplace is that everything is an object,
/// all tracking of listings would be done with an indexer.  Tokens are owned
/// by the listings.  Listings are owned by the marketplace and the marketplace
/// is owned by its creator.
///
/// TODO: Collection offers
/// TODO: Fungible asset support
/// TODO: Other object support
module marketplace_contract::marketplace {

    use aptos_framework::aptos_account;
    use aptos_framework::coin;
    use aptos_framework::event::{Self, EventHandle, emit_event};
    use aptos_framework::object::{Self, Object, DeleteRef, ExtendRef, new_event_handle};
    use aptos_framework::timestamp;
    use aptos_std::math64;
    use aptos_token_objects::royalty;
    use aptos_token_objects::token;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    /// Listing not found
    const ELISTING_NOT_FOUND: u64 = 1;
    /// Price below minimum listing price
    const EPRICE_BELOW_MINIMUM: u64 = 2;
    /// Listing has expired
    const ELISTING_EXPIRED: u64 = 3;
    /// Cannot remove listing, signer is not seller of token
    const ENOT_SELLER: u64 = 4;
    /// Cannot list token, signer is not owner of token
    const ENOT_OWNER: u64 = 5;
    /// Listing expiration time is less than 5 minutes
    const ETOO_SHORT_DURATION: u64 = 6;
    /// Denominator cannot be 0
    const EDENOMINATOR_ZERO: u64 = 7;
    /// Commission is 100% or greater
    const ECOMMISSION_TOO_HIGH: u64 = 8;
    /// Marketplace for coin not found
    const EMARKETPLACE_NOT_FOUND: u64 = 9;
    /// Not authorized to modify marketplace, not the owner of the marketplace
    const ENOT_AUTHORIZED: u64 = 10;
    /// Bid must be strictly larger than the previous bid
    const EBID_TOO_LOW: u64 = 11;
    /// No bid found
    const ENO_BID_FOUND: u64 = 12;
    /// Auction not yet over
    const EAUCTION_NOT_OVER: u64 = 13;
    /// Listing not on Marketplace
    const ELISTING_NOT_ON_MARKETPLACE: u64 = 14;

    const FIVE_MINUTES_SECS: u64 = 300;

    /// A listing for a single Token object on the market place
    ///
    /// The listing will own the token until it is bought by a buyer or it is
    /// removed from listing.
    /// TODO: Allow extending the expiration time?
    struct Listing<phantom CoinType> has key {
        /// Token to be sold.  While listed, this listing will own the token
        item: Object<token::Token>,
        /// Seller of the token
        seller: address,
        /// Minimum price accepted for a bid
        min_bid: u64,
        /// Price accepted for instant buy
        price: u64,
        /// timestamp in secs for the listing starting time
        start_time_seconds: u64,
        /// timestamp in secs for the listing expiration time, after this time the auction can be completed
        expiration_time_seconds: u64,
        /// The current highest bid on the auction
        highest_bid: Option<Bid<CoinType>>,
        /// Refs for modifying the listing
        listing_refs: ListingRefs,
        /// Events on changes to the listing state
        events: EventHandle<ListingEvent>,
    }

    /// Combined events for an individual listing
    struct ListingEvent has drop, store {
        item: Object<token::Token>,
        start: Option<StartEvent>,
        bid: Option<BidEvent>,
        sale: Option<SaleEvent>,
        end: Option<EndEvent>
    }

    /// An event specifying the start of an auction
    struct StartEvent has drop, store {
        price: u64,
        start_time_secs: u64,
        end_time_secs: u64,
    }

    /// An event specifying that an auction was ended in a sale
    ///
    /// The distribution of payouts are shown accordingly
    struct SaleEvent has drop, store {
        buyer: address,
        price: u64,
        commission: u64,
        royalties: u64
    }

    /// An event specifying that an auction was ended with no sale
    struct EndEvent has drop, store {}

    /// An event specifying the before and after state of a bid
    struct BidEvent has drop, store {
        new_bidder: address,
        new_bid: u64,
        old_bidder: Option<address>,
        old_bid: Option<u64>,
    }

    /// A representation of a bid by a single user
    struct Bid<phantom CoinType> has key, store {
        /// Address of the bidder for this specific bid
        bidder: address,
        /// Stored coins from the bid
        coins: coin::Coin<CoinType>
    }

    /// A standalone resource that represents the marketplace in it's entirety
    ///
    /// This also allows you to list in other currencies than the native coin
    /// TODO: add events for listings?
    struct Marketplace<phantom CoinType> has key {
        fee_schedule: FeeSchedule,
        extend_ref: ExtendRef,
        /// An event stream of changes to the fee schedule
        fee_mutation_events: event::EventHandle<FeeMutationEvent>,
    }

    /// Event notifying when any of the fees are modified
    struct FeeMutationEvent has drop, store {
        mutated_field_name: String,
    }

    /// Administrative object references to keep the listing working
    struct ListingRefs has store, drop {
        extend_ref: ExtendRef,
        delete_ref: Option<DeleteRef>,
    }

    /// Extracts the delete ref to delete a listing
    fun take_delete_ref(listing_refs: ListingRefs): DeleteRef {
        option::extract(&mut listing_refs.delete_ref)
    }

    /// The desciption of all fees on the marketplace, it allows for
    /// listing fees to prevent spam, as well as commissions to take a percentage
    /// of each sale.
    struct FeeSchedule has store, drop {
        /// Address to send fees to
        fee_address: address,
        /// A fixed fee for making a listing
        listing_fee: u64,
        /// A fixed fee for making a bid
        bid_fee: u64,
        /// Numerator on the percentage fee of a listing sale
        commission_numerator: u64,
        /// Denominator on the percentage fee of a listing sale
        commission_denominator: u64,
    }

    // -- Admin functions --

    /// Initialize a marketplace
    entry fun init_marketplace<CoinType>(
        account: &signer,
        bid_fee: u64,
        listing_fee: u64,
        commission_numerator: u64,
        commission_denominator: u64
    ) {
        init_marketplace_internal<CoinType>(
            account,
            bid_fee,
            listing_fee,
            commission_numerator,
            commission_denominator
        );
    }

    fun init_marketplace_internal<CoinType>(
        marketplace_owner: &signer,
        bid_fee: u64,
        listing_fee: u64,
        commission_numerator: u64,
        commission_denominator: u64
    ): address {
        let marketplace_owner_address = signer::address_of(marketplace_owner);
        check_commission(commission_numerator, commission_denominator);

        // TODO: Do we make the marketplace address deterministic?
        let marketplace_constructor = object::create_object_from_account(marketplace_owner);
        let extend_ref = object::generate_extend_ref(&marketplace_constructor);
        let marketplace_signer = object::generate_signer(&marketplace_constructor);

        let marketplace = Marketplace<CoinType> {
            fee_schedule: FeeSchedule {
                // Start fee address as the deployer
                fee_address: marketplace_owner_address,
                bid_fee,
                listing_fee,
                commission_numerator,
                commission_denominator,
            },
            extend_ref,
            fee_mutation_events: new_event_handle<FeeMutationEvent>(&marketplace_signer)
        };

        move_to(&marketplace_signer, marketplace);
        signer::address_of(&marketplace_signer)
    }

    /// Set the address that fees are sent to
    entry fun set_fee_address<CoinType>(
        marketplace_owner: &signer,
        marketplace_address: address,
        fee_address: address
    ) acquires Marketplace {
        let marketplace = borrow_marketplace_mut<CoinType>(marketplace_owner, marketplace_address);
        marketplace.fee_schedule.fee_address = fee_address;
        event::emit_event(&mut marketplace.fee_mutation_events, FeeMutationEvent {
            mutated_field_name: string::utf8(b"Fee address")
        });
    }

    /// Set the fee charged on every listing
    entry fun set_listing_fee<CoinType>(
        marketplace_owner: &signer,
        marketplace_address: address,
        listing_fee: u64
    ) acquires Marketplace {
        let marketplace = borrow_marketplace_mut<CoinType>(marketplace_owner, marketplace_address);
        marketplace.fee_schedule.listing_fee = listing_fee;
        event::emit_event(&mut marketplace.fee_mutation_events, FeeMutationEvent {
            mutated_field_name: string::utf8(b"Listing fee")
        });
    }

    /// Set the fee charged on every bid
    entry fun set_bid_fee<CoinType>(
        marketplace_owner: &signer,
        marketplace_address: address,
        bid_fee: u64
    ) acquires Marketplace {
        let marketplace = borrow_marketplace_mut<CoinType>(marketplace_owner, marketplace_address);
        marketplace.fee_schedule.bid_fee = bid_fee;
        event::emit_event(&mut marketplace.fee_mutation_events, FeeMutationEvent {
            mutated_field_name: string::utf8(b"Bid fee")
        });
    }

    /// Set the commission made on every sale
    ///
    /// Note: This cannot be > 50%
    entry fun set_commission<CoinType>(
        marketplace_owner: &signer,
        marketplace_address: address,
        numerator: u64,
        denominator: u64
    ) acquires Marketplace {
        check_commission(numerator, denominator);

        let marketplace = borrow_marketplace_mut<CoinType>(marketplace_owner, marketplace_address);
        marketplace.fee_schedule.commission_numerator = numerator;
        marketplace.fee_schedule.commission_denominator = denominator;
        event::emit_event(&mut marketplace.fee_mutation_events, FeeMutationEvent {
            mutated_field_name: string::utf8(b"Commission")
        });
    }

    /// We don't allow > 50% commission
    inline fun check_commission(numerator: u64, denominator: u64) {
        assert!(denominator != 0, EDENOMINATOR_ZERO);
        assert!(numerator <= (denominator / 2), ECOMMISSION_TOO_HIGH);
    }

    // -- Marketplace functions --

    /// List a token for sale with a given instant buy price
    entry fun list_token_object<ObjectType: key, Coin>(
        seller: &signer,
        marketplace_address: address,
        token: Object<ObjectType>,
        min_bid: u64,
        price: u64,
        duration_seconds: u64
    ) acquires Marketplace {
        list_token_object_inner<ObjectType, Coin>(seller, marketplace_address, token, min_bid, price, duration_seconds);
    }

    /// Internal helper function to allow tests to know what the address of the listings are
    ///
    /// Normally, this would be handled with an indexer
    fun list_token_object_inner<ObjectType: key, CoinType>(
        seller: &signer,
        marketplace_address: address,
        token: Object<ObjectType>,
        min_bid: u64,
        price: u64,
        duration_seconds: u64
    ): address acquires Marketplace {
        // Ensure that the seller is the owner of the token
        let seller_address = signer::address_of(seller);
        assert!(object::is_owner(token, seller_address), ENOT_OWNER);

        assert!(duration_seconds > FIVE_MINUTES_SECS, ETOO_SHORT_DURATION);

        // Only support tokens or derivatives of it
        // TODO: provide better error messaging
        let token_object = object::convert<ObjectType, token::Token>(token);

        // Determine listing end time
        let start_time_seconds = timestamp::now_seconds();
        let expiration_time_seconds = start_time_seconds + duration_seconds;

        // Build the Listing object and derive it from the marketplace
        let marketplace = borrow_marketplace<CoinType>(marketplace_address);
        let marketplace_signer = object::generate_signer_for_extending(&marketplace.extend_ref);

        let listing_object_constructor_ref = object::create_object_from_object(&marketplace_signer);
        let listing_extend_ref = object::generate_extend_ref(&listing_object_constructor_ref);
        let listing_delete_ref = object::generate_delete_ref(&listing_object_constructor_ref);
        let listing_address = object::address_from_constructor_ref(&listing_object_constructor_ref);
        let listing_signer = object::generate_signer(&listing_object_constructor_ref);

        let listing = Listing<CoinType> {
            item: token_object,
            seller: seller_address,
            min_bid,
            price,
            start_time_seconds,
            expiration_time_seconds,
            highest_bid: option::none(),
            listing_refs: ListingRefs {
                extend_ref: listing_extend_ref,
                delete_ref: option::some(listing_delete_ref),
            },
            events: new_event_handle(&listing_signer)
        };

        emit_event(&mut listing.events, ListingEvent {
            item: token_object,
            start: option::some(StartEvent {
                price,
                start_time_secs: start_time_seconds,
                end_time_secs: expiration_time_seconds,
            }),
            bid: option::none(),
            sale: option::none(),
            end: option::none(),
        });
        move_to(&listing_signer, listing);

        // Take listing fee
        if (marketplace.fee_schedule.listing_fee > 0) {
            aptos_account::transfer_coins<CoinType>(
                seller,
                marketplace.fee_schedule.fee_address,
                marketplace.fee_schedule.listing_fee
            );
        };

        // Point the token to this listing
        object::transfer(seller, token, listing_address);
        listing_address
    }

    /// Removes a listing from the marketplace
    ///
    /// This is disincentivized from being done often with the listing fee
    entry fun remove_listing<CoinType>(
        seller: &signer,
        listing_address: address,
    ) acquires Listing {
        // Ensure that the seller matches
        let listing = borrow_listing_mut<CoinType>(listing_address);
        let seller_address = signer::address_of(seller);
        assert!(seller_address == listing.seller, ENOT_SELLER);

        // Return bid if it exists
        if (option::is_some(&listing.highest_bid)) {
            let Bid {
                bidder,
                coins
            } = option::extract(&mut listing.highest_bid);
            aptos_account::deposit_coins<CoinType>(bidder, coins);
        };

        emit_event(&mut listing.events, ListingEvent {
            item: listing.item,
            start: option::none(),
            bid: option::none(),
            sale: option::none(),
            end: option::some(EndEvent {})
        });

        // Point token V2 back to the original seller
        transfer_and_drop_listing<CoinType, token::Token>(listing_address, listing.item, seller_address);
    }

    /// Accepts the highest current bid on a listing
    ///
    /// The seller can decide to end the auction early, but otherwise it will take
    /// the bid at the end.
    entry fun accept_highest_bid<CoinType>(
        seller: &signer,
        marketplace_address: address,
        listing_address: address,
    ) acquires Marketplace, Listing {
        assert_listing_on_marketplace<CoinType>(marketplace_address, listing_address);

        let marketplace = borrow_marketplace<CoinType>(marketplace_address);

        // Ensure that the seller matches
        let listing = borrow_listing_mut<CoinType>(listing_address);
        let seller_address = signer::address_of(seller);
        assert!(seller_address == listing.seller, ENOT_SELLER);

        // Buy with the bid
        assert!(option::is_some(&listing.highest_bid), ENO_BID_FOUND);
        let Bid {
            bidder,
            coins,
        } = option::extract(&mut listing.highest_bid);
        buy_listing(marketplace, listing_address, bidder, coins);
    }

    /// Completes an auction if it has expired.
    ///
    /// Anyone can run this, so it allows the seller and the bidder to end the auction
    entry fun complete_auction<CoinType>(
        seller: &signer,
        marketplace_address: address,
        listing_address: address,
    ) acquires Marketplace, Listing {
        assert_listing_on_marketplace<CoinType>(marketplace_address, listing_address);

        // Ensure that the seller matches
        let listing = borrow_listing_mut<CoinType>(listing_address);
        assert!(timestamp::now_seconds() > listing.expiration_time_seconds, EAUCTION_NOT_OVER);

        if (option::is_some(&listing.highest_bid)) {
            accept_highest_bid<CoinType>(seller, marketplace_address, listing_address);
        } else {
            remove_listing<CoinType>(seller, listing_address);
        };
    }

    /// Make a bid on a listing
    entry fun bid<CoinType>(
        bidder: &signer,
        marketplace_address: address,
        listing_address: address,
        price: u64,
    ) acquires Marketplace, Listing {
        let bidder_address = signer::address_of(bidder);
        assert_listing_on_marketplace<CoinType>(marketplace_address, listing_address);
        let marketplace = borrow_marketplace<CoinType>(marketplace_address);

        // Ensure the listing hasn't expired
        let listing = borrow_listing_mut(listing_address);
        assert!(listing.expiration_time_seconds >= timestamp::now_seconds(), ELISTING_EXPIRED);

        // Remove the bid fee if there is one
        if (marketplace.fee_schedule.bid_fee > 0) {
            aptos_account::transfer_coins<CoinType>(
                bidder,
                marketplace.fee_schedule.fee_address,
                marketplace.fee_schedule.bid_fee
            );
        };

        // Check if the bid is higher than the previous one
        let (old_bid, old_bidder) = if (option::is_some(&listing.highest_bid)) {
            let bid = option::borrow<Bid<CoinType>>(&mut listing.highest_bid);
            let old_bid = coin::value(&bid.coins);
            assert!(price > old_bid, EBID_TOO_LOW);
            (option::some(old_bid), option::some(bid.bidder))
        } else {
            // Bid must be greater than 0
            assert!(price >= listing.min_bid, EBID_TOO_LOW);
            (option::none(), option::none())
        };

        emit_event(&mut listing.events, ListingEvent {
            item: listing.item,
            start: option::none(),
            bid: option::some(BidEvent {
                old_bid,
                old_bidder,
                new_bid: price,
                new_bidder: bidder_address
            }),
            sale: option::none(),
            end: option::none()
        });

        // Return the previous bid
        return_bid(listing);

        let coins = coin::withdraw<CoinType>(bidder, price);
        option::fill(&mut listing.highest_bid,
            Bid {
                bidder: bidder_address,
                coins
            });
    }

    /// Buys multiple tokens at once
    entry fun buy_multiple_tokens<CoinType>(
        buyer: &signer,
        marketplace_address: address,
        listing_addresses: vector<address>,
    ) acquires Marketplace, Listing {
        // This is a slight optimization over borrowing each time
        let marketplace = borrow_marketplace<CoinType>(marketplace_address);
        let i = 0;
        let length = vector::length(&listing_addresses);
        while (i < length) {
            let listing_address = vector::pop_back(&mut listing_addresses);
            assert_listing_on_marketplace<CoinType>(marketplace_address, listing_address);
            buy_token_inner<CoinType>(buyer, marketplace, listing_address);
            i = i + 1;
        }
    }

    /// Buys a token at a given price, requires that the token price is greater than the min price
    ///
    /// This will handle all commissions and royalties
    entry fun buy_token<CoinType>(
        buyer: &signer,
        marketplace_address: address,
        listing_address: address,
    ) acquires Marketplace, Listing {
        assert_listing_on_marketplace<CoinType>(marketplace_address, listing_address);
        let marketplace = borrow_marketplace<CoinType>(marketplace_address);
        buy_token_inner(buyer, marketplace, listing_address);
    }

    inline fun buy_token_inner<CoinType>(
        buyer: &signer,
        marketplace: &Marketplace<CoinType>,
        listing_address: address
    ) {
        // Ensure the listing hasn't expired
        let listing = borrow_listing_mut<CoinType>(listing_address);
        assert!(listing.expiration_time_seconds >= timestamp::now_seconds(), ELISTING_EXPIRED);

        // Withdraw full price from buyer
        let coins = coin::withdraw<CoinType>(buyer, listing.price);

        buy_listing(marketplace, listing_address, signer::address_of(buyer), coins);
    }

    /// Buys a listing with all commission and royalties taken out
    inline fun buy_listing<CoinType>(
        marketplace: &Marketplace<CoinType>,
        listing_address: address,
        buyer_address: address,
        coins: coin::Coin<CoinType>
    ) {
        let price = coin::value(&coins);
        let listing = borrow_listing_mut<CoinType>(listing_address);

        // Return any outstanding bids
        return_bid<CoinType>(listing);

        // Transfer the royalties before commission, creators deserve to be paid first
        let royalty_resource = token::royalty(listing.item);
        let royalties = if (option::is_some(&royalty_resource)) {
            let royalty = option::extract(&mut royalty_resource);
            let royalty_address = royalty::payee_address(&royalty);
            let numerator = royalty::numerator(&royalty);
            let denominator = royalty::denominator(&royalty);
            let royalty_amount = (price * numerator) / denominator;

            let royalty_coins = coin::extract(&mut coins, royalty_amount);
            aptos_account::deposit_coins(royalty_address, royalty_coins);
            royalty_amount
        } else {
            0
        };

        // Take commission percentage, which might be less than expected depending on royalties + commission
        let commission = if (marketplace.fee_schedule.commission_numerator > 0) {
            let commission = (price * marketplace.fee_schedule.commission_numerator) / marketplace.fee_schedule.commission_denominator;
            let num_coins_left = coin::value(&coins);
            let actual_commission = math64::min(num_coins_left, commission);
            let commission_coins = coin::extract(&mut coins, actual_commission);
            aptos_account::deposit_coins(marketplace.fee_schedule.fee_address, commission_coins);
            commission
        } else {
            0
        };

        // Transfer the remaining to the seller
        aptos_account::deposit_coins(listing.seller, coins);
        emit_event(&mut listing.events, ListingEvent {
            item: listing.item,
            start: option::none(),
            bid: option::none(),
            sale: option::some(SaleEvent {
                price,
                buyer: buyer_address,
                commission,
                royalties,
            }),
            end: option::none()
        });

        // Transfer the token to the buyer
        transfer_and_drop_listing<CoinType, token::Token>(listing_address, listing.item, buyer_address);
    }

    /// Returns the current highest bid to the original owner
    inline fun return_bid<CoinType>(listing: &mut Listing<CoinType>) {
        if (option::is_some(&listing.highest_bid)) {
            let Bid {
                bidder,
                coins
            } = option::extract(&mut listing.highest_bid);

            aptos_account::deposit_coins(bidder, coins);
        };
    }

    // -- View functions --

    #[view]
    /// Get information about the marketplace's fees
    fun get_fee_schedule<CoinType>(marketplace_address: address): FeeSchedule acquires Marketplace {
        let fee_schedule = &borrow_marketplace<CoinType>(marketplace_address).fee_schedule;
        FeeSchedule {
            bid_fee: fee_schedule.bid_fee,
            fee_address: fee_schedule.fee_address,
            listing_fee: fee_schedule.listing_fee,
            commission_numerator: fee_schedule.commission_numerator,
            commission_denominator: fee_schedule.commission_denominator,
        }
    }

    struct ListingView {
        marketplace: address,
        item: Object<token::Token>,
        seller: address,
        price: u64,
        start_time_seconds: u64,
        expiration_time_seconds: u64,
    }

    #[view]
    /// Get information about a specific listing
    fun get_listing<CoinType>(
        listing_address: address
    ): ListingView acquires Listing {
        let listing_object = object::address_to_object<Listing<CoinType>>(listing_address);
        let listing = borrow_listing<CoinType>(listing_address);

        // TODO: Add the latest bid as well
        ListingView {
            marketplace: object::owner(listing_object),
            item: listing.item,
            seller: listing.seller,
            price: listing.price,
            start_time_seconds: listing.start_time_seconds,
            expiration_time_seconds: listing.expiration_time_seconds,
        }
    }

    // -- Helper functions --

    inline fun assert_listing_on_marketplace<CoinType>(
        marketplace_address: address,
        listing_address: address
    ) {
        // First check if the marketplace and listing exist
        assert!(
            object::is_object(marketplace_address) && exists<Marketplace<CoinType>>(marketplace_address),
            EMARKETPLACE_NOT_FOUND
        );
        assert!(object::is_object(listing_address) && exists<Listing<CoinType>>(listing_address), ELISTING_NOT_FOUND);
        let listing_object = object::address_to_object<Listing<CoinType>>(listing_address);
        assert!(object::is_owner(listing_object, marketplace_address), ELISTING_NOT_ON_MARKETPLACE);
    }

    inline fun borrow_marketplace_mut<CoinType>(
        marketplace_owner: &signer,
        marketplace_address: address
    ): &mut Marketplace<CoinType> {
        assert!(
            object::is_owner(
                object::address_to_object<Marketplace<CoinType>>(marketplace_address),
                signer::address_of(marketplace_owner)
            ),
            ENOT_AUTHORIZED
        );
        assert!(exists<Marketplace<CoinType>>(marketplace_address), EMARKETPLACE_NOT_FOUND);
        borrow_global_mut<Marketplace<CoinType>>(marketplace_address)
    }

    inline fun borrow_marketplace<CoinType>(marketplace_address: address): &Marketplace<CoinType> {
        assert!(exists<Marketplace<CoinType>>(marketplace_address), EMARKETPLACE_NOT_FOUND);
        borrow_global<Marketplace<CoinType>>(marketplace_address)
    }

    inline fun borrow_listing_mut<CoinType>(
        listing_address: address
    ): &mut Listing<CoinType> {
        assert!(object::is_object(listing_address) && exists<Listing<CoinType>>(listing_address), ELISTING_NOT_FOUND);
        borrow_global_mut<Listing<CoinType>>(listing_address)
    }

    inline fun borrow_listing<CoinType>(
        listing_address: address
    ): &Listing<CoinType> {
        assert!(object::is_object(listing_address) && exists<Listing<CoinType>>(listing_address), ELISTING_NOT_FOUND);
        borrow_global<Listing<CoinType>>(listing_address)
    }

    inline fun transfer_and_drop_listing<CoinType, T: key>(
        listing_address: address,
        item: Object<T>,
        destination_address: address
    ) {
        // Transfer the item
        let listing = borrow_listing_mut<CoinType>(listing_address);
        let listing_signer = object::generate_signer_for_extending(&listing.listing_refs.extend_ref);
        object::transfer(&listing_signer, item, destination_address);
        let delete_ref = option::extract(&mut listing.listing_refs.delete_ref);
        // Drop the listing
        object::delete(delete_ref);
    }

    // -- Tests --

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin::AptosCoin;
    #[test_only]
    use aptos_framework::coin::FakeMoney;
    #[test_only]
    use aptos_token_objects::aptos_token::{Self, AptosToken};

    #[test_only]
    const FAKE_MONEY_BASE: u64 = 100000000;
    #[test_only]
    const HOUR_SECONDS: u64 = 3600;
    #[test_only]
    const COLLECTION_NAME: vector<u8> = b"Wacky Wombats";
    #[test_only]
    const TOKEN_NAME_1: vector<u8> = b"Wilson";
    #[test_only]
    const TOKEN_NAME_2: vector<u8> = b"William";
    #[test_only]
    const TOKEN_NAME_3: vector<u8> = b"Woodrow";
    #[test_only]
    const MIN_BID: u64 = 1;
    #[test_only]
    const LIST_PRICE: u64 = 100000000 * 2;
    #[test_only]
    const LIST_FEE: u64 = 5000000;
    #[test_only]
    const BID_FEE: u64 = 1000;
    #[test_only]
    const BID_AMOUNT: u64 = 5;

    #[test(framework = @0x1, marketplace_owner = @0xAAAA, creator = @0xDEAD, seller = @0xBEEF, buyer = @0x1337)]
    /// Tests listing, and completing listings via direct sale, or rejecting sales
    fun test_listing(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
        buyer: &signer
    ) acquires Marketplace, Listing {
        // Setup initial state
        let marketplace_owner_address = signer::address_of(marketplace_owner);
        let marketplace_address = setup_marketplace(framework, marketplace_owner);
        let creator_address = signer::address_of(creator);
        let seller_address = signer::address_of(seller);
        let buyer_address = signer::address_of(buyer);
        account::create_account_for_test(creator_address);
        account::create_account_for_test(seller_address);
        account::create_account_for_test(buyer_address);

        // Create money to transfer to the creator and buyer to pay for things
        aptos_account::transfer_coins<FakeMoney>(framework, creator_address, 20 * FAKE_MONEY_BASE);
        aptos_account::transfer_coins<FakeMoney>(framework, seller_address, 50 * FAKE_MONEY_BASE);
        aptos_account::transfer_coins<FakeMoney>(framework, buyer_address, 30 * FAKE_MONEY_BASE);

        let tokens = create_simple_collection(creator);
        let token_1 = vector::pop_back(&mut tokens);
        let token_2 = vector::pop_back(&mut tokens);
        let token_3 = vector::pop_back(&mut tokens);

        // Transfer token 1 and 2 to the seller
        object::transfer(creator, token_1, seller_address);
        object::transfer(creator, token_2, seller_address);

        assert_owner(token_1, seller_address);
        assert_owner(token_2, seller_address);
        assert_owner(token_3, creator_address);

        // List token_1
        let pre_list_marketplace_balance = coin::balance<FakeMoney>(marketplace_owner_address);
        let pre_list_balance = coin::balance<FakeMoney>(seller_address);
        let listing_address_1 = list_token_object_inner<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_1,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );

        // Ensure the listing exists and that the list fee was taken out
        assert_owner(token_1, listing_address_1);
        let post_list_balance = coin::balance<FakeMoney>(seller_address);
        assert!(pre_list_balance == (post_list_balance + LIST_FEE), 1);
        let post_list_marketplace_balance = coin::balance<FakeMoney>(marketplace_owner_address);
        assert!(post_list_marketplace_balance == (pre_list_marketplace_balance + LIST_FEE), 1);

        let listing = borrow_global<Listing<FakeMoney>>(listing_address_1);
        assert!(listing.seller == seller_address, 1);
        // TODO: Check more about the item

        // List other tokens
        let listing_address_2 = list_token_object_inner<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_2,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );
        let listing_address_3 = list_token_object_inner<AptosToken, FakeMoney>(
            creator,
            marketplace_address,
            token_3,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );
        assert_owner(token_2, listing_address_2);
        assert_owner(token_3, listing_address_3);

        // Remove the first listing
        remove_listing<FakeMoney>(seller, listing_address_1);
        assert_owner(token_1, seller_address);
        assert_listing_deleted(listing_address_1);

        // Sell the second listing, ensuring that the buyer now owns the token and the listing is destroyed
        // Royalties should be paid, and commission should be paid
        let pre_sale_marketplace_balance = coin::balance<FakeMoney>(marketplace_owner_address);
        let pre_sale_seller_balance = coin::balance<FakeMoney>(seller_address);
        let pre_sale_creator_balance = coin::balance<FakeMoney>(creator_address);
        let pre_sale_buyer_balance = coin::balance<FakeMoney>(buyer_address);

        buy_token<FakeMoney>(buyer, marketplace_address, listing_address_2);
        assert_owner(token_2, buyer_address);
        assert_listing_deleted(listing_address_2);

        // Validate that royalties and commissions occur and add up to the total amount transferred
        let post_sale_marketplace_balance = coin::balance<FakeMoney>(marketplace_owner_address);
        let post_sale_seller_balance = coin::balance<FakeMoney>(seller_address);
        let post_sale_creator_balance = coin::balance<FakeMoney>(creator_address);
        let post_sale_buyer_balance = coin::balance<FakeMoney>(buyer_address);
        assert!(pre_sale_buyer_balance == post_sale_buyer_balance + LIST_PRICE, 1);
        assert!(pre_sale_marketplace_balance < post_sale_marketplace_balance, 1);
        assert!(pre_sale_seller_balance < post_sale_seller_balance, 1);
        assert!(pre_sale_creator_balance < post_sale_creator_balance, 1);
        assert!(
            (post_sale_creator_balance - pre_sale_creator_balance
                + post_sale_marketplace_balance - pre_sale_marketplace_balance
                + post_sale_seller_balance - pre_sale_seller_balance) == LIST_PRICE,
            1
        );

        // Remove the 3rd listing, which will be the creator not the seller
        buy_multiple_tokens<FakeMoney>(buyer, marketplace_address, vector[listing_address_3]);
        assert_owner(token_3, buyer_address);
        assert_listing_deleted(listing_address_3);
    }

    #[test(framework = @0x1, marketplace_owner = @0xAAAA, creator = @0xDEAD, seller = @0xBEEF, buyer = @0x1337)]
    /// Tests fees on direct sales
    fun test_zero_fees(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
        buyer: &signer
    ) acquires Marketplace, Listing {
        // Setup initial state
        let marketplace_owner_address = signer::address_of(marketplace_owner);
        let marketplace_address = setup_marketplace(framework, marketplace_owner);
        set_commission<FakeMoney>(marketplace_owner, marketplace_address, 0, 100);
        set_listing_fee<FakeMoney>(marketplace_owner, marketplace_address, 0);
        set_bid_fee<FakeMoney>(marketplace_owner, marketplace_address, 0);
        let creator_address = signer::address_of(creator);
        let seller_address = signer::address_of(seller);
        let buyer_address = signer::address_of(buyer);
        account::create_account_for_test(creator_address);
        account::create_account_for_test(seller_address);
        account::create_account_for_test(buyer_address);

        // Create money to transfer to the creator and buyer to pay for things
        aptos_account::transfer_coins<FakeMoney>(framework, creator_address, 20 * FAKE_MONEY_BASE);
        aptos_account::transfer_coins<FakeMoney>(framework, seller_address, 50 * FAKE_MONEY_BASE);
        aptos_account::transfer_coins<FakeMoney>(framework, buyer_address, 30 * FAKE_MONEY_BASE);

        let tokens = create_simple_collection(creator);
        let token_1 = vector::pop_back(&mut tokens);

        // Transfer token 1 and 2 to the seller
        object::transfer(creator, token_1, seller_address);

        assert_owner(token_1, seller_address);

        // List token_1
        let pre_list_marketplace_balance = coin::balance<FakeMoney>(marketplace_owner_address);
        let pre_list_balance = coin::balance<FakeMoney>(seller_address);
        let listing_address_1 = list_token_object_inner<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_1,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );

        // Ensure the listing exists and that there was no list fee
        assert_owner(token_1, listing_address_1);
        let post_list_balance = coin::balance<FakeMoney>(seller_address);
        assert!(pre_list_balance == post_list_balance, 1);
        let post_list_marketplace_balance = coin::balance<FakeMoney>(marketplace_address);
        assert!(post_list_marketplace_balance == pre_list_marketplace_balance, 1);

        // Sell it, and there should only be royalties and the seller value (no commission)
        let pre_sale_marketplace_balance = coin::balance<FakeMoney>(marketplace_address);
        let pre_sale_seller_balance = coin::balance<FakeMoney>(seller_address);
        let pre_sale_creator_balance = coin::balance<FakeMoney>(creator_address);
        let pre_sale_buyer_balance = coin::balance<FakeMoney>(buyer_address);

        buy_token<FakeMoney>(buyer, marketplace_address, listing_address_1);
        assert_owner(token_1, buyer_address);
        assert_listing_deleted(listing_address_1);

        // Validate that royalties occur and add up to the total amount transferred
        let post_sale_marketplace_balance = coin::balance<FakeMoney>(marketplace_address);
        let post_sale_seller_balance = coin::balance<FakeMoney>(seller_address);
        let post_sale_creator_balance = coin::balance<FakeMoney>(creator_address);
        let post_sale_buyer_balance = coin::balance<FakeMoney>(buyer_address);
        assert!(pre_sale_buyer_balance == post_sale_buyer_balance + LIST_PRICE, 1);
        assert!(pre_sale_marketplace_balance == post_sale_marketplace_balance, 1);
        assert!(pre_sale_seller_balance < post_sale_seller_balance, 1);
        assert!(pre_sale_creator_balance < post_sale_creator_balance, 1);
        assert!(
            (post_sale_creator_balance - pre_sale_creator_balance
                + post_sale_seller_balance - pre_sale_seller_balance) == LIST_PRICE,
            1
        );
    }

    #[test(
        framework = @0x1,
        marketplace_owner = @0xAAAA,
        creator = @0xDEAD,
        seller = @0xBEEF,
        buyer_1 = @0x1337,
        buyer_2 = @0xB0B
    )]
    /// Tests bidding ending early
    fun test_bidding_end_early(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
        buyer_1: &signer,
        buyer_2: &signer
    ) acquires Marketplace, Listing {
        let (marketplace_address, token_1) = prep_single_listing(
            framework,
            marketplace_owner,
            creator,
            seller
        );
        let buyer_1_address = signer::address_of(buyer_1);
        account::create_account_for_test(buyer_1_address);
        aptos_account::transfer_coins<FakeMoney>(framework, buyer_1_address, 15 * FAKE_MONEY_BASE);
        let buyer_2_address = signer::address_of(buyer_2);
        account::create_account_for_test(buyer_2_address);
        aptos_account::transfer_coins<FakeMoney>(framework, buyer_2_address, 15 * FAKE_MONEY_BASE);

        // List token_1
        let listing_address_1 = list_token_object_inner<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_1,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );

        // One person bids, the fee, and the bid amount should be taken out
        let buyer_1_pre_bid_balance = coin::balance<FakeMoney>(buyer_1_address);
        bid<FakeMoney>(buyer_1, marketplace_address, listing_address_1, BID_AMOUNT);
        let buyer_1_post_bid_balance = coin::balance<FakeMoney>(buyer_1_address);
        assert!((buyer_1_post_bid_balance + BID_AMOUNT + BID_FEE) == buyer_1_pre_bid_balance, 1);

        let buyer_2_pre_bid_balance = coin::balance<FakeMoney>(buyer_2_address);
        bid<FakeMoney>(buyer_2, marketplace_address, listing_address_1, 2 * BID_AMOUNT);

        let buyer_2_post_bid_balance = coin::balance<FakeMoney>(buyer_2_address);
        let buyer_1_post_buyer_2_balance = coin::balance<FakeMoney>(buyer_1_address);
        assert!((buyer_2_post_bid_balance + 2 * BID_AMOUNT + BID_FEE) == buyer_2_pre_bid_balance, 1);

        // Original buyer gets refunded (but not the fee)
        assert!((buyer_1_pre_bid_balance - BID_FEE) == buyer_1_post_buyer_2_balance, 1);

        // Seller decides to end early
        accept_highest_bid<FakeMoney>(seller, marketplace_address, listing_address_1);
        assert_owner(token_1, buyer_2_address);

        // TODO: Check fees?
    }

    #[test(
        framework = @0x1,
        marketplace_owner = @0xAAAA,
        creator = @0xDEAD,
        seller = @0xBEEF,
        buyer_1 = @0x1337,
    )]
    /// Tests bidding ending after the end of the auction
    fun test_bidding_complete_auction(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
        buyer_1: &signer,
    ) acquires Marketplace, Listing {
        let (marketplace_address, token_1) = prep_single_listing(
            framework,
            marketplace_owner,
            creator,
            seller
        );
        let buyer_1_address = signer::address_of(buyer_1);
        account::create_account_for_test(buyer_1_address);
        aptos_account::transfer_coins<FakeMoney>(framework, buyer_1_address, 15 * FAKE_MONEY_BASE);

        // List token_1
        let listing_address_1 = list_token_object_inner<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_1,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );

        bid<FakeMoney>(buyer_1, marketplace_address, listing_address_1, BID_AMOUNT);
        timestamp::fast_forward_seconds(HOUR_SECONDS + 1);

        // One bid, so buyer 1 gets it
        complete_auction<FakeMoney>(seller, marketplace_address, listing_address_1);
        assert_owner(token_1, buyer_1_address);
    }

    #[test(
        framework = @0x1,
        marketplace_owner = @0xAAAA,
        creator = @0xDEAD,
        seller = @0xBEEF,
    )]
    /// Tests bidding ending after the end of the auction with no bids
    fun test_bidding_no_bids(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
    ) acquires Marketplace, Listing {
        let (marketplace_address, token_1) = prep_single_listing(
            framework,
            marketplace_owner,
            creator,
            seller
        );

        // List token_1
        let listing_address_1 = list_token_object_inner<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_1,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );

        timestamp::fast_forward_seconds(HOUR_SECONDS + 1);

        // No bids, means we transfer back to the original
        complete_auction<FakeMoney>(seller, marketplace_address, listing_address_1);
        assert_owner(token_1, signer::address_of(seller));
    }


    #[test(framework = @0x1, marketplace_owner = @0xAAAA, creator = @0xDEAD, seller = @0xBEEF)]
    #[expected_failure(abort_code = ENOT_SELLER, location = Self)]
    /// Tests someone who isn't the seller trying to remove the listing
    fun test_not_seller_remove_listing(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
    ) acquires Marketplace, Listing {
        let (marketplace_address, token_1) = prep_single_listing(
            framework,
            marketplace_owner,
            creator,
            seller
        );

        // List token_1
        let listing_address_1 = list_token_object_inner<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_1,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );

        // Have someone else try to delist it
        remove_listing<FakeMoney>(marketplace_owner, listing_address_1);
    }

    #[test(framework = @0x1, marketplace_owner = @0xAAAA, creator = @0xDEAD, seller = @0xBEEF)]
    #[expected_failure(abort_code = ELISTING_EXPIRED, location = Self)]
    /// Tests trying to direct buy an expired listing
    fun test_buy_listing_expired(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
    ) acquires Marketplace, Listing {
        let (marketplace_address, token_1) = prep_single_listing(
            framework,
            marketplace_owner,
            creator,
            seller
        );

        let listing_address_1 = list_token_object_inner<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_1,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );

        // Try to buy after too much time has passed
        timestamp::fast_forward_seconds(HOUR_SECONDS + 1);
        buy_token<FakeMoney>(creator, marketplace_address, listing_address_1);
    }

    #[test(framework = @0x1, marketplace_owner = @0xAAAA, creator = @0xDEAD, seller = @0xBEEF)]
    #[expected_failure(abort_code = ETOO_SHORT_DURATION, location = Self)]
    /// Tests trying to list an auction for less than 5 minutes
    fun test_list_too_short_time(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
    ) acquires Marketplace {
        let (marketplace_address, token_1) = prep_single_listing(
            framework,
            marketplace_owner,
            creator,
            seller
        );

        list_token_object<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_1,
            MIN_BID,
            LIST_PRICE,
            5
        );
    }

    #[test(framework = @0x1, marketplace_owner = @0xAAAA, creator = @0xDEAD, seller = @0xBEEF)]
    fun test_fee_address_rotation(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
    ) acquires Marketplace {
        let (marketplace_address, token_1) = prep_single_listing(
            framework,
            marketplace_owner,
            creator,
            seller
        );
        set_fee_address<FakeMoney>(marketplace_owner, marketplace_address, @0x1);

        let seller_address = signer::address_of(seller);
        let framework_pre_list_balance = coin::balance<FakeMoney>(@0x1);
        let seller_pre_list_balance = coin::balance<FakeMoney>(seller_address);
        list_token_object<AptosToken, FakeMoney>(
            seller,
            marketplace_address,
            token_1,
            MIN_BID,
            LIST_PRICE,
            HOUR_SECONDS
        );
        let framework_post_list_balance = coin::balance<FakeMoney>(@0x1);
        let seller_post_list_balance = coin::balance<FakeMoney>(seller_address);
        assert!(framework_post_list_balance > framework_pre_list_balance, 1);
        assert!(
            framework_post_list_balance - framework_pre_list_balance == seller_pre_list_balance - seller_post_list_balance,
            1
        );
    }

    #[test(framework = @0x1, marketplace_owner = @0xAAAA)]
    #[expected_failure(abort_code = EDENOMINATOR_ZERO, location = Self)]
    fun test_zero_denominator(
        framework: &signer,
        marketplace_owner: &signer,
    ) acquires Marketplace {
        let marketplace_address = setup_marketplace(framework, marketplace_owner);
        set_commission<FakeMoney>(marketplace_owner, marketplace_address, 0, 0);
    }

    #[test(framework = @0x1, marketplace_owner = @0xAAAA)]
    #[expected_failure(abort_code = ECOMMISSION_TOO_HIGH, location = Self)]
    fun test_more_than_50_percent_commission(
        framework: &signer,
        marketplace_owner: &signer,
    ) acquires Marketplace {
        let marketplace_address = setup_marketplace(framework, marketplace_owner);
        set_commission<FakeMoney>(marketplace_owner, marketplace_address, 51, 100);
    }

    #[test(framework = @0x1, marketplace_owner = @0xAAAA)]
    #[expected_failure(abort_code = EMARKETPLACE_NOT_FOUND, location = Self)]
    fun test_invalid_marketplace(
        framework: &signer,
        marketplace_owner: &signer,
    ) acquires Listing, Marketplace {
        setup_marketplace(framework, marketplace_owner);
        bid<AptosCoin>(marketplace_owner, @0x1234, @0x345, 1);
    }

    #[test(framework = @0x1, marketplace_owner = @0xAAAA)]
    #[expected_failure(abort_code = ELISTING_NOT_FOUND, location = Self)]
    fun test_invalid_listing(
        framework: &signer,
        marketplace_owner: &signer,
    ) acquires Listing {
        setup_marketplace(framework, marketplace_owner);
        remove_listing<FakeMoney>(marketplace_owner, @0x1234);
    }

    #[test(framework = @0x1, marketplace_owner = @0xAAAA)]
    fun test_fee_schedule(
        framework: &signer,
        marketplace_owner: &signer,
    ) acquires Marketplace {
        let marketplace_owner_address = signer::address_of(marketplace_owner);
        let marketplace_address = setup_marketplace(framework, marketplace_owner);
        let fee_schedule = get_fee_schedule<FakeMoney>(marketplace_address);
        assert!(fee_schedule.bid_fee == BID_FEE, 1);
        assert!(fee_schedule.listing_fee == LIST_FEE, 1);
        assert!(fee_schedule.fee_address == marketplace_owner_address, 1);
        assert!(fee_schedule.commission_numerator == 1, 1);
        assert!(fee_schedule.commission_denominator == 100, 1);
    }

    // -- Test helpers --

    #[test_only]
    fun prep_single_listing(
        framework: &signer,
        marketplace_owner: &signer,
        creator: &signer,
        seller: &signer,
    ): (address, Object<AptosToken>) {
        let marketplace_address = setup_marketplace(framework, marketplace_owner);
        let creator_address = signer::address_of(creator);
        let seller_address = signer::address_of(seller);
        account::create_account_for_test(creator_address);
        account::create_account_for_test(seller_address);

        // Create money to transfer to the creator and buyer to pay for things
        aptos_account::transfer_coins<FakeMoney>(framework, creator_address, 20 * FAKE_MONEY_BASE);
        aptos_account::transfer_coins<FakeMoney>(framework, seller_address, 50 * FAKE_MONEY_BASE);

        let tokens = create_simple_collection(creator);
        let token_1 = vector::pop_back(&mut tokens);

        // Transfer token 1 and 2 to the seller
        object::transfer(creator, token_1, seller_address);

        assert_owner(token_1, seller_address);
        (marketplace_address, token_1)
    }

    #[test_only]
    fun assert_owner<T: key>(object: Object<T>, owner: address) {
        assert!(object::is_owner(object, owner), 2);
    }

    #[test_only]
    fun assert_listing_deleted(listing_address: address) {
        assert!(!object::is_object(listing_address), 3);
    }

    #[test_only]
    fun setup_marketplace(framework: &signer, marketplace_owner: &signer): address {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(framework));
        account::create_account_for_test(signer::address_of(marketplace_owner));
        coin::create_fake_money(framework, marketplace_owner, 100 * FAKE_MONEY_BASE);
        let marketplace_address = init_marketplace_internal<FakeMoney>(marketplace_owner, BID_FEE, LIST_FEE, 1, 100);
        account::create_account_for_test(marketplace_address);
        aptos_account::transfer_coins<FakeMoney>(framework, marketplace_address, 0);
        marketplace_address
    }

    #[test_only]
    fun create_simple_collection(creator: &signer): vector<Object<AptosToken>> {
        create_collection(
            creator,
            string::utf8(COLLECTION_NAME),
            vector[string::utf8(TOKEN_NAME_1), string::utf8(TOKEN_NAME_2), string::utf8(TOKEN_NAME_3)]
        )
    }

    #[test_only]
    fun create_collection(
        creator: &signer,
        collection_name: String,
        token_names: vector<String>
    ): vector<Object<AptosToken>> {
        aptos_token::create_collection(
            creator,
            string::utf8(b"collection description"),
            3,
            collection_name,
            string::utf8(b"collection uri"),
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            1,
            100,
        );

        let tokens = vector[];
        let i = 0;
        let length = vector::length(&token_names);
        while (i < length) {
            let token_name = vector::borrow(&token_names, i);
            let token = mint(creator, collection_name, *token_name);
            vector::push_back(&mut tokens, token);
            i = i + 1;
        };

        tokens
    }

    #[test_only]
    fun mint(
        creator: &signer,
        collection_name: String,
        token_name: String,
    ): Object<AptosToken> {
        let creator_addr = signer::address_of(creator);
        let token_creation_num = account::get_guid_next_creation_num(creator_addr);

        aptos_token::mint(
            creator,
            collection_name,
            string::utf8(b"description"),
            token_name,
            string::utf8(b"uri"),
            vector[string::utf8(b"bool")],
            vector[string::utf8(b"bool")],
            vector[vector[0x01]],
        );
        object::address_to_object<AptosToken>(object::create_guid_object_address(creator_addr, token_creation_num))
    }
}
