// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Criteria for allowed posts.
/// @custom:member hook The hook to which this allowance applies.
/// @custom:member category A category that should allow posts.
/// @custom:member minimumPrice The minimum price that a post to the specified category should cost.
/// @custom:member minimumTotalSupply The minimum total supply of NFTs that can be made available when minting.
/// @custom:member maxTotalSupply The max total supply of NFTs that can be made available when minting. Leave as 0 for
/// max.
/// @custom:member allowedAddresses A list of addresses that are allowed to post on the category through Croptop.
struct CTAllowedPost {
    address hook;
    uint256 category;
    uint256 minimumPrice;
    uint256 minimumTotalSupply;
    uint256 maximumTotalSupply;
    address[] allowedAddresses;
}
