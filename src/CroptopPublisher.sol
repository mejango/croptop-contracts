// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";
import "@jbx-protocol/juice-721-delegate/contracts/interfaces/IJBTiered721Delegate.sol";

/**
 * @notice
 * Criteria for allowed posts.
 *
 * @member nft The NFT to which this allowance applies.
 * @member category A category that should allow posts.
 * @member minimumPrice The minimum price that a post to the specified category should cost.
 * @member minimumQuantity The minimum quantity of NFTs that can be made available when minting.
 */
struct AllowedPost {
    address nft;
    uint256 category;
    uint256 minimumPrice;
    uint256 minimumQuantity;
}

/**
 * @notice
 * A post to be published.
 *
 * @member encodedIPFSUri The encoded IPFS URI of the post that is being published.
 * @member quantity The quantity of NFTs that should be made available, including the 1 that will be minted alongside this transaction.
 * @member price The price being paid for buying the post that is being published.
 * @member category The category that the post should be published in.
 */
struct Post {
    bytes32 encodedIPFSUri;
    uint32 quantity;
    uint88 price;
    uint16 category;
}

/**
 * @notice
 * A contract that facilitates the distribution of NFT posts to a Juicebox project.
 */
contract CroptopPublisher {
    error INVALID_MINIMUM_QUANTITY();
    error INCOMPATIBLE_DATA_SOURCE();
    error INSUFFICIENT_AMOUNT();
    error INSUFFICIENT_QUANTITY();
    error INVALID_FEE_PERCENT();
    error UNAUTHORIZED();
    error UNAUTHORIZED_CATEGORY();

    event Collected(
        uint256 projectId, Post[] posts, address nftBeneficiary, address feeBeneficiary, uint256 fee, address caller
    );

    /**
     * @notice
     * Packed values that determine the allowance of posts.
     *
     * _projectId The ID of the project.
     * _nft The NFT contract for which this allowance applies.
     * _category The category for which the allowance applies
     */
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) internal _packedAllowanceFor;

    /**
     * @notice
     * The divisor that describes the fee that should be taken.
     *
     * @dev
     * This is equal to 100 divided by the fee percent.
     */
    uint256 public feeDivisor = 20;

    /**
     * @notice
     * The controller that directs the projects being posted to.
     */
    IJBController3_1 public controller;

    /**
     * @notice
     * The ID of the tier that an IPFS metadata has been saved to.
     *
     * _projectId The ID of the project.
     * _encodedIPFSUri The IPFS URI.
     */
    mapping(uint256 => mapping(bytes32 => uint256)) public tierIdForEncodedIPFSUriOf;

    /**
     * @notice
     * The ID of the project to which fees will be routed.
     */
    uint256 public feeProjectId;

    /**
     * @notice
     * Get the tiers for the provided encoded IPFS URIs.
     *
     *  @param _projectId The ID of the project from which the tiers are being sought.
     *  @param _nft The NFT from which to get tiers.
     *  @param _encodedIPFSUris The URIs to get tiers of.
     *
     *  @return tiers The tiers that correspond to the provided encoded IPFS URIs. If there's no tier yet, an empty tier is returned.
     */
    function tiersFor(uint256 _projectId, address _nft, bytes32[] memory _encodedIPFSUris)
        external
        view
        returns (JB721Tier[] memory tiers)
    {
        uint256 _numberOfEncodedIPFSUris = _encodedIPFSUris.length;

        if (_nft == address(0)) {
            // Get the projects current data source from its current funding cyce's metadata.
            (, JBFundingCycleMetadata memory _metadata) = controller.currentFundingCycleOf(_projectId);

            // Set the NFT as the data source.
            _nft = _metadata.dataSource;
        }

        // Get the tier for each provided encoded IPFS URI.
        for (uint256 _i; _i < _numberOfEncodedIPFSUris;) {
            // Check if there's a tier ID stored for the encoded IPFS URI.
            uint256 _tierId = tierIdForEncodedIPFSUriOf[_projectId][_encodedIPFSUris[_i]];

            // If there's a tier ID stored, resolve it.
            if (_tierId != 0) {
                tiers[_i] = IJBTiered721Delegate(_nft).store().tierOf(_nft, _tierId, false);
            }

            unchecked {
                ++_i;
            }
        }
    }

    /**
     * @notice
     * Post allowances for a particular category on a particular NFT.
     *
     * @param _projectId The ID of the project.
     * @param _nft The NFT contract for which this allowance applies.
     * @param _category The category for which this allowance applies.
     *
     * @return minimumPrice The minimum price that a poster must pay to record a new NFT.
     * @return minimumQuantity The minimum quantity that a minter must set to record a new NFT.
     */
    function allowanceFor(uint256 _projectId, address _nft, uint256 _category)
        public
        view
        returns (uint256 minimumPrice, uint256 minimumQuantity)
    {
        // Get a reference to the packed values.
        uint256 _packed = _packedAllowanceFor[_projectId][_nft][_category];

        // minimum price in bits 0-103 (104 bits).
        minimumPrice = uint256(uint104(_packed));
        // minimum price in bits 104-135 (32 bits).
        minimumQuantity = uint256(uint32(_packed >> 104));
    }

    /**
     * @param _controller The controller that directs the projects being posted to.
     * @param _feeProjectId The ID of the project to which fees will be routed.
     */
    constructor(IJBController3_1 _controller, uint256 _feeProjectId) {
        controller = _controller;
        feeProjectId = _feeProjectId;
    }

    /**
     * @notice
     * Publish an NFT to become mintable, and mint a first copy.
     *
     * @dev
     * A fee is taken into the appropriate treasury.
     *
     * @param _projectId The ID of the project to which the NFT should be added.
     * @param _posts An array of posts that should be published as NFTs to the specified project.
     * @param _nftBeneficiary The beneficiary of the NFT mints.
     * @param _feeBeneficiary The beneficiary of the fee project's token.
     */
    function collect(uint256 _projectId, Post[] memory _posts, address _nftBeneficiary, address _feeBeneficiary)
        external
        payable
    {
        // Get the projects current data source from its current funding cyce's metadata.
        (, JBFundingCycleMetadata memory _metadata) = controller.currentFundingCycleOf(_projectId);

        // Check to make sure the project's current data source is a IJBTiered721Delegate.
        if (!IERC165(_metadata.dataSource).supportsInterface(type(IJBTiered721Delegate).interfaceId)) {
            revert INCOMPATIBLE_DATA_SOURCE();
        }

        // Keep a reference to the tier data that will be created to represent the posts.
        // Keep a reference to the tier IDs of the posts that should be minted once published.
        // Keep a reference to the total price being paid.
        (JB721TierParams[] memory _tierDataToAdd, uint256[] memory _tierIdsToMint, uint256 _totalPrice) =
            _setupPosts(_projectId, _metadata.dataSource, _posts);

        // Keep a reference to the fee that will be paid.
        uint256 _fee;

        // Determine the applicable fee.
        _fee = _projectId == feeProjectId ? 0 : (_totalPrice / feeDivisor);

        // Make sure the amount sent to this function is at least the specified price of the tier plus the fee.
        if (_totalPrice + _fee < msg.value) {
            revert INSUFFICIENT_AMOUNT();
        }

        // Add the new tiers.
        IJBTiered721Delegate(_metadata.dataSource).adjustTiers(_tierDataToAdd, new uint256[](0));

            // Get a reference to the project's current ETH payment terminal.
            IJBPaymentTerminal _projectTerminal = controller.directory().primaryTerminalOf(_projectId, JBTokens.ETH);

            // Create the metadata for the payment to specify the tier IDs that should be minted.
            bytes memory _mintMetadata = abi.encode(
                bytes32(feeProjectId), // Referral project ID.
                bytes32(0),
                type(IJBTiered721Delegate).interfaceId,
                true, // Allow overspending.
                _tierIdsToMint
            );

            // Make the payment.
            _projectTerminal.pay{value: msg.value - _fee}(
                _projectId,
                msg.value - _fee,
                JBTokens.ETH,
                _nftBeneficiary,
                0,
                false,
                "Minted from Croptop",
                _mintMetadata
            );

        // Pay a fee if there are funds left.
        if (address(this).balance != 0) {
            // Get a reference to the fee project's current ETH payment terminal.
            IJBPaymentTerminal _feeTerminal = controller.directory().primaryTerminalOf(feeProjectId, JBTokens.ETH);

            // Referral project ID.
            bytes memory _feeMetadata = abi.encode(bytes32(feeProjectId));

            // Make the fee payment.
            _feeTerminal.pay{value: address(this).balance}(
                feeProjectId, address(this).balance, JBTokens.ETH, _feeBeneficiary, 0, false, "", _feeMetadata
            );
        }

        emit Collected(_projectId, _posts, _nftBeneficiary, _feeBeneficiary, _fee, msg.sender);
    }

    /**
     * @notice
     * Project owners can set the allowed criteria for publishing a new NFT to their project.
     *
     * @param _projectId The ID of the project having its publishing allowances set.
     * @param _allowedPosts An array of criteria for allowed posts.
     */
    function configure(uint256 _projectId, AllowedPost[] memory _allowedPosts) external {
        // Make sure the caller is the owner of the project.
        if (msg.sender != controller.projects().ownerOf(_projectId)) {
            revert UNAUTHORIZED();
        }

        // Get the projects current data source from its current funding cyce's metadata.
        (, JBFundingCycleMetadata memory _metadata) = controller.currentFundingCycleOf(_projectId);

        // Keep a reference to the number of post criteria.
        uint256 _numberOfAllowedPosts = _allowedPosts.length;

        // Keep a reference to the post criteria being iterated on.
        AllowedPost memory _allowedPost;

        // For each post criteria, save the specifications.
        for (uint256 _i; _i < _numberOfAllowedPosts;) {
            // Set the post criteria being iterated on.
            _allowedPost = _allowedPosts[_i];

            // Make sure there is a minimum quantity.
            if (_allowedPost.minimumQuantity == 0) {
                revert INVALID_MINIMUM_QUANTITY();
            }

            // Set the _nft as the current data source if not set.
            if (_allowedPost.nft == address(0)) {
                _allowedPost.nft = _metadata.dataSource;
            }

            uint256 _packed;
            // minimum price in bits 0-103 (104 bits).
            _packed |= uint256(_allowedPost.minimumPrice);
            // minimum quantity in bits 104-135 (32 bits).
            _packed |= uint256(_allowedPost.minimumQuantity) << 104;
            // Store the packed value.
            _packedAllowanceFor[_projectId][_allowedPost.nft][_allowedPost.category] = _packed;

            unchecked {
                ++_i;
            }
        }
    }

    /** 
      @notice 
      Setup the posts.

      @param _projectId The ID of the project having posts set up.
      @param _nft The NFT address on which the posts will apply.
      @param _posts An array of posts that should be published as NFTs to the specified project.

      @return tierDataToAdd The tier data that will be created to represent the posts.
      @return tierIdsToMint The tier IDs of the posts that should be minted once published.
      @return totalPrice The total price being paid.
    */ 
    function _setupPosts(uint256 _projectId, address _nft, Post[] memory _posts)
        internal
        returns (JB721TierParams[] memory tierDataToAdd, uint256[] memory tierIdsToMint, uint256 totalPrice)
    {
        // Scoped section to prevent stack too deep.
        {
            // Keep a reference to the number of posts being published.
            uint256 _numberOfMints = _posts.length;

            // Set the max size of the tier data that will be added.
            tierDataToAdd = new JB721TierParams[](
                _numberOfMints
            );

            // Set the size of the tier IDs of the posts that should be minted once published.
            tierIdsToMint = new uint256[](_numberOfMints);

            // The tier ID that will be created, and the first one that should be minted from, is one more than the current max.
            uint256 _startingTierId = IJBTiered721Delegate(_nft).store().maxTierIdOf(_nft) + 1;

            // Keep a reference to the post being iterated on.
            Post memory _post;

            // Keep a reference to the total number of tiers being added.
            uint256 _numberOfTiersBeingAdded;

            // For each post, create tiers after validating to make sure they fulfill the allowance specified by the project's owner.
            for (uint256 _i; _i < _numberOfMints;) {
                // Get the current post being iterated on.
                _post = _posts[_i];

                // Scoped section to prevent stack too deep.
                {
                    // Check if there's an ID of a tier already minted for this encodedIPFSUri.
                    uint256 _tierId = tierIdForEncodedIPFSUriOf[_projectId][_post.encodedIPFSUri];

                    if (_tierId != 0) tierIdsToMint[_i] = _tierId;
                }

                // If no tier already exists, post the tier.
                if (tierIdsToMint[_i] == 0) {
                    // Get references to the allowance.
                    (uint256 _minimumPrice, uint256 _minimumQuantity) = allowanceFor(_projectId, _nft, _post.category);

                    // Make sure the category being posted to allows publishing.
                    if (_minimumQuantity == 0) {
                        revert UNAUTHORIZED_CATEGORY();
                    }

                    // Make sure the price being paid for the post is at least the allowed minimum price.
                    if (_post.price < _minimumPrice) {
                        revert INSUFFICIENT_AMOUNT();
                    }

                    // Make sure the quantity being made available for the post is at least the allowed minimum quantity.
                    if (_post.quantity < _minimumQuantity) {
                        revert INSUFFICIENT_QUANTITY();
                    }

                    // Set the tier.
                    tierDataToAdd[_numberOfTiersBeingAdded] = JB721TierParams({
                        price: uint80(_post.price),
                        initialQuantity: _post.quantity,
                        votingUnits: 0,
                        reservedRate: 0,
                        reservedTokenBeneficiary: address(0),
                        encodedIPFSUri: _post.encodedIPFSUri,
                        category: uint8(_post.category),
                        allowManualMint: false,
                        shouldUseReservedTokenBeneficiaryAsDefault: false,
                        transfersPausable: false,
                        useVotingUnits: true
                    });

                    // Increment the number of tiers being added.
                    _numberOfTiersBeingAdded++;

                    // Set the ID of the tier to mint.
                    tierIdsToMint[_i] = _startingTierId + _numberOfTiersBeingAdded;

                    // Save the encodedIPFSUri as minted.
                    tierIdForEncodedIPFSUriOf[_projectId][_post.encodedIPFSUri] = tierIdsToMint[_i];
                }

                // Increment the total price.
                totalPrice += _post.price;

                unchecked {
                    ++_i;
                }
            }

            // Add the new tiers if needed.
            if (_numberOfTiersBeingAdded != 0) {
                // Resize the array if there's a mismatch in length.
                if (_numberOfTiersBeingAdded != tierDataToAdd.length) {
                    assembly ("memory-safe") {
                        mstore(tierDataToAdd, _numberOfTiersBeingAdded)
                    }
                }
            }
        }
    }
}