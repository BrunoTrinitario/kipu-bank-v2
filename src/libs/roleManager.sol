pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

contract RoleManager is AccessControl {
    error attemptToRevokeAdminRoleFromInitialAdmin();
    error Unauthorized();
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    address public adminAddress;
    event roleAdded(bytes32 role, address account);
    event roleRemoved(bytes32 role, address account);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONFIG_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        adminAddress = msg.sender;
    }

    function setAdminRole(address account) external onlyAdmin() {
        _grantRole(DEFAULT_ADMIN_ROLE, account);
        emit roleAdded(DEFAULT_ADMIN_ROLE, account);
    }

    function revokeAdminRole(address account) external onlyAdmin() {
        if (account == adminAddress) {
            revert attemptToRevokeAdminRoleFromInitialAdmin();
        }
        _revokeRole(DEFAULT_ADMIN_ROLE, account);
        emit roleRemoved(DEFAULT_ADMIN_ROLE, account);
    }

    function setConfigRole(address account) external onlyAdmin() {
        _grantRole(CONFIG_ROLE, account);
        emit roleAdded(CONFIG_ROLE, account);
    }

    function setPauserRole(address account) external onlyAdmin() {
        _grantRole(PAUSER_ROLE, account);
        emit roleAdded(PAUSER_ROLE, account);
    }

    function revokeConfigRole(address account) external onlyAdmin() {
        _revokeRole(CONFIG_ROLE, account);
        emit roleRemoved(CONFIG_ROLE, account);
    }

    function revokePauserRole(address account) external onlyAdmin() {
        _revokeRole(PAUSER_ROLE, account);
        emit roleRemoved(PAUSER_ROLE, account);
    }

    function hasConfigRole(address account) external view returns (bool) {
        return hasRole(CONFIG_ROLE, account);
    }

    function hasPauserRole(address account) external view returns (bool) {
        return hasRole(PAUSER_ROLE, account);
    }

    function hasAdminRole(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }

    function getAvailableRoles() external pure returns (bytes32[] memory) {
        bytes32 ;
        roles[0] = CONFIG_ROLE;
        roles[1] = PAUSER_ROLE;
        return roles;
    }

    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), Unauthorized());
        _;
    }

    modifier onlyConfig() {
        require(hasRole(CONFIG_ROLE, msg.sender), Unauthorized());
        _;
    }

    modifier onlyPauser() {
        require(hasRole(PAUSER_ROLE, msg.sender), Unauthorized());
        _;
    }
}