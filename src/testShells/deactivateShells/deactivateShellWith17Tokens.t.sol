pragma solidity ^0.5.6;

import "ds-test/test.sol";

import "../../Prototype.sol";
import "../../ERC20Token.sol";
import "../../Shell.sol";
import "../../ShellFactory.sol";
import "../../testSetup/setupShells.sol";

contract DappTest is DSTest, ShellSetup {
    address shell;

    function setUp() public {

        setupPool();
        setupTokens();
        shell = setup17TokenShell();
        pool.setMinCapital(10000 * (10 ** 18));
        uint256 amounts = 10000 * (10 ** 18);
        pool.depositLiquidity(shell, amounts);
        pool.activateShell(shell);
        pool.withdrawLiquidity(shell, amounts * 17);

    }

    function testDeactivateShellWith17Tokens () public {
        pool.deactivateShell(shell);
    }

}