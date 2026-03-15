// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IGmxDataStore {
    function getUint(bytes32 key) external view returns (uint256);
    function getAddress(bytes32 key) external view returns (address);
    function getInt(bytes32 key) external view returns (int256);
    function getBool(bytes32 key) external view returns (bool);
    function getBytes32(bytes32 key) external view returns (bytes32);
    function getBytes32Count(bytes32 setKey) external view returns (uint256);
    function getBytes32ValuesAt(bytes32 setKey, uint256 start, uint256 end) external view returns (bytes32[] memory);
}
