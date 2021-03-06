
pragma solidity ^0.5.12;

import "./LoihiRoot.sol";
import "./LoihiDelegators.sol";

contract LoihiLiquidity is LoihiRoot, LoihiDelegators {

    /// @author james foley http://github.com/realisation
    /// @dev this function is used in selective deposits and selective withdraws
    /// @dev it finds the reserves corresponding to the flavors and attributes the amounts to these reserves
    /// @param _flavors the addresses of the stablecoin flavor
    /// @param _amounts the specified amount of each stablecoin flavor
    /// @return three arrays each the length of the number of reserves containing the balances, token amounts and weights for each reserve
    function getBalancesTokenAmountsAndWeights (address[] memory _flavors, uint256[] memory _amounts) private returns (uint256[] memory, uint256[] memory, uint256[] memory) {

        uint256[] memory balances_ = new uint256[](reserves.length);
        uint256[] memory tokenAmounts_ = new uint256[](reserves.length);
        uint256[] memory weights_ = new uint[](reserves.length);

        for (uint i = 0; i < _flavors.length; i++) {
            Flavor memory _f = flavors[_flavors[i]]; // withdrawing adapter + weight
            for (uint j = 0; j < reserves.length; j++) {
                balances_[j] = dGetNumeraireBalance(reserves[j]);
                if (reserves[j] == _f.reserve) {
                    tokenAmounts_[j] += dGetNumeraireAmount(_f.adapter, _amounts[i]);
                    weights_[j] = _f.weight;
                }
            }
        }

        return (balances_, tokenAmounts_, weights_);

    }

    event log_uint(bytes32, uint256);

    event log_uints(bytes32, uint256[]);

    /// @author james foley http://github.com/realisation
    /// @notice this function allows selective depositing of any supported stablecoin flavor into the contract in return for corresponding shell tokens
    /// @param _flavors an array containing the addresses of the flavors being deposited into
    /// @param _amounts an array containing the values of the flavors you wish to deposit into the contract. each amount should have the same index as the flavor it is meant to deposit
    /// @return shellsToMint_ the amount of shells to mint for the deposited stablecoin flavors
    function selectiveDeposit (address[] calldata _flavors, uint256[] calldata _amounts, uint256 _minShells, uint256 _deadline) external nonReentrant returns (uint256 shellsToMint_) {
        require(_deadline >= now, "deadline has passed for this transaction");

        ( uint256[] memory _balances,
          uint256[] memory _deposits,
          uint256[] memory _weights ) = getBalancesTokenAmountsAndWeights(_flavors, _amounts);

        emit log_uints("balances", _balances);
        emit log_uints("deposits", _deposits);
        emit log_uints("weights", _weights);

        shellsToMint_ = calculateShellsToMint(_balances, _deposits, _weights);

        emit log_uint("shells to mint", shellsToMint_);

        require(shellsToMint_ >= _minShells, "minted shells less than minimum shells");

        _mint(msg.sender, shellsToMint_);

        for (uint i = 0; i < _flavors.length; i++) dIntakeRaw(flavors[_flavors[i]].adapter, _amounts[i]);

        emit ShellsMinted(msg.sender, shellsToMint_, _flavors, _amounts);

        return shellsToMint_;

    }

    /// @author james foley http://github.com/realisation
    /// @notice this function calculates the amount of shells to mint by taking the balances, numeraire deposits and weights of the reserve tokens being deposited into
    /// @dev each array is the same length. each index in each array refers to the same reserve - index 0 is for the reserve token at index 0 in the reserves array, index 1 is for the reserve token at index 1 in the reserve array and so forth.
    /// @param _balances an array of current numeraire balances for each reserve
    /// @param _deposits an array of numeraire amounts to deposit into each reserve
    /// @param _weights an array of the balance weights for each of the reserves
    /// @return shellsToMint_ the amount of shell tokens to mint according to the dynamic fee relative to the balance of each reserve deposited into
    function calculateShellsToMint (uint256[] memory _balances, uint256[] memory _deposits, uint256[] memory _weights) private returns (uint256) {

        uint256 _newSum;
        uint256 _oldSum;
        for (uint i = 0; i < _balances.length; i++) {
            _oldSum = add(_oldSum, _balances[i]);
            _newSum = add(_newSum, add(_balances[i], _deposits[i]));
        }

        uint256 shellsToMint_;

        for (uint i = 0; i < _balances.length; i++) {
            if (_deposits[i] == 0) continue;
            uint256 _depositAmount = _deposits[i];
            uint256 _weight = _weights[i];
            uint256 _oldBalance = _balances[i];
            uint256 _newBalance = add(_oldBalance, _depositAmount);

            require(_newBalance <= wmul(_weight, wmul(_newSum, alpha + WAD)), "halt check deposit");

            uint256 _feeThreshold = wmul(_weight, wmul(_newSum, beta + WAD));
            if (_newBalance <= _feeThreshold) {

                shellsToMint_ += _depositAmount;
                emit log_uint("shells to mint no fee", shellsToMint_);

            } else if (_oldBalance >= _feeThreshold) {

                uint256 _feePrep = wmul(feeDerivative, wdiv(
                    sub(_newBalance, _feeThreshold),
                    wmul(_weight, _newSum)
                ));

                shellsToMint_ = add(shellsToMint_, wmul(_depositAmount, WAD - _feePrep));
                emit log_uint("shells to mint all fee", shellsToMint_);

            } else {

                uint256 _feePrep = wmul(feeDerivative, wdiv(
                    sub(_newBalance, _feeThreshold),
                    wmul(_weight, _newSum)
                ));

                shellsToMint_ += add(
                    sub(_feeThreshold, _oldBalance),
                    wmul(sub(_newBalance, _feeThreshold), WAD - _feePrep)
                );

                emit log_uint("shells to mint all fee", shellsToMint_);

            }
        }
        emit log_uint("After", shellsToMint_);
        emit log_uint("total supply", totalSupply);
        uint256 adjusted = wmul(totalSupply, wdiv(shellsToMint_, _oldSum));
        emit log_uint("adjusted shells 2 mint", adjusted);
        return adjusted;

    }

    /// @author james foley http://github.com/realisation
    /// @notice this function allows selective the withdrawal of any supported stablecoin flavor from the contract by burning a corresponding amount of shell tokens
    /// @param _flavors an array of flavors to withdraw from the reserves
    /// @param _amounts an array of amounts to withdraw that maps to _flavors
    /// @return shellsBurned_ the corresponding amount of shell tokens to withdraw the specified amount of specified flavors
    function selectiveWithdraw (address[] calldata _flavors, uint256[] calldata _amounts, uint256 _maxShells, uint256 _deadline) external nonReentrant returns (uint256 shellsBurned_) {
        require(_deadline >= now, "deadline has passed for this transaction");

        ( uint256[] memory _balances,
          uint256[] memory _withdrawals,
          uint256[] memory _weights ) = getBalancesTokenAmountsAndWeights(_flavors, _amounts);

        shellsBurned_ = calculateShellsToBurn(_balances, _withdrawals, _weights);

        require(shellsBurned_ <= _maxShells, "more shells burned than max shell limit");

        for (uint i = 0; i < _flavors.length; i++) dOutputRaw(flavors[_flavors[i]].adapter, msg.sender, _amounts[i]);

        _burn(msg.sender, shellsBurned_);

        emit ShellsBurned(msg.sender, shellsBurned_, _flavors, _amounts);

        return shellsBurned_;

    }

    /// @author james foley http://github.com/realisation
    /// @notice this function calculates the amount of shells to mint by taking the balances, numeraire deposits and weights of the reserve tokens being deposited into
    /// @dev each array is the same length. each index in each array refers to the same reserve - index 0 is for the reserve token at index 0 in the reserves array, index 1 is for the reserve token at index 1 in the reserve array and so forth.
    /// @param _balances an array of current numeraire balances for each reserve
    /// @param _withdrawals an array of numeraire amounts to deposit into each reserve
    /// @param _weights an array of the balance weights for each of the reserves
    /// @return shellsToBurn_ the amount of shell tokens to burn according to the dynamic fee of each withdraw relative to the balance of each reserve
    function calculateShellsToBurn (uint256[] memory _balances, uint256[] memory _withdrawals, uint256[] memory _weights) internal returns (uint256) {

        uint256 _newSum;
        uint256 _oldSum;
        for (uint i = 0; i < _balances.length; i++) {
            _oldSum = add(_oldSum, _balances[i]);
            _newSum = add(_newSum, sub(_balances[i], _withdrawals[i]));
        }

        uint256 _numeraireShellsToBurn;

        for (uint i = 0; i < reserves.length; i++) {
            if (_withdrawals[i] == 0) continue;
            uint256 _withdrawal = _withdrawals[i];
            uint256 _weight = _weights[i];
            uint256 _oldBal = _balances[i];
            uint256 _newBal = sub(_oldBal, _withdrawal);

            require(_newBal >= wmul(_weight, wmul(_newSum, WAD - alpha)), "withdraw halt check");

            uint256 _feeThreshold = wmul(_weight, wmul(_newSum, WAD - beta));

            if (_newBal >= _feeThreshold) {

                _numeraireShellsToBurn += wmul(_withdrawal, WAD + feeBase);

            } else if (_oldBal <= _feeThreshold) {

                uint256 _feePrep = wdiv(sub(_feeThreshold, _newBal), wmul(_weight, _newSum));

                _feePrep = wmul(_feePrep, feeDerivative);

                _numeraireShellsToBurn += wmul(wmul(_withdrawal, WAD + _feePrep), WAD + feeBase);

            } else {

                uint256 _feePrep = wdiv(sub(_feeThreshold, _newBal), wmul(_weight, _newSum));

                _feePrep = wmul(feeDerivative, _feePrep);

                _numeraireShellsToBurn += wmul(add(
                    sub(_oldBal, _feeThreshold),
                    wmul(sub(_feeThreshold, _newBal), WAD + _feePrep)
                ), WAD + feeBase);

            }
        }

        return wmul(totalSupply, wdiv(_numeraireShellsToBurn, _oldSum));

    }

    /// @author james foley http://github.com/realisation
    /// @notice this function takes a total amount to deposit into the pool with no slippage from the numeraire assets the pool supports
    /// @param _deposit the full amount you want to deposit into the pool which will be divided up evenly amongst the numeraire assets of the pool
    /// @return shellsToMint_ the amount of shells you receive in return for your deposit
    function proportionalDeposit (uint256 _deposit) public returns (uint256) {

        uint256 _totalBalance;
        uint256 _totalSupply = totalSupply;

        uint256[] memory _amounts = new uint256[](3);

        for (uint i = 0; i < reserves.length; i++) {
            Flavor memory _f = flavors[numeraires[i]];
            _amounts[i] = wmul(_f.weight, _deposit);
            _totalBalance += dGetNumeraireBalance(reserves[i]);
        }

        if (_totalBalance == 0) {
            _totalBalance = WAD;
            _totalSupply = WAD;
        }

        uint256 shellsToMint_ = wmul(_deposit, wdiv(_totalBalance, _totalSupply));

        _mint(msg.sender, shellsToMint_);

        for (uint i = 0; i < reserves.length; i++) {
            Flavor memory d = flavors[numeraires[i]];
           _amounts[i] = dIntakeNumeraire(d.adapter, _amounts[i]);
        }

        emit ShellsMinted(msg.sender, shellsToMint_, numeraires, _amounts);

        return shellsToMint_;

    }

    /// @author james foley http://github.com/realisation
    /// @notice this function takes a total amount to from the the pool with no slippage from the numeraire assets of the pool
    /// @param _withdrawal the full amount you want to withdraw from the pool which will be withdrawn from evenly amongst the numeraire assets of the pool
    /// @return withdrawnAmts_ the amount withdrawn from each of the numeraire assets
    function proportionalWithdraw (uint256 _withdrawal) public nonReentrant returns (uint256[] memory) {

        uint256 _withdrawMultiplier = wdiv(_withdrawal, totalSupply);

        _burn(msg.sender, _withdrawal);
        emit ShellsBurned(msg.sender, _withdrawal);

        uint256[] memory withdrawalAmts_ = new uint256[](reserves.length);
        for (uint i = 0; i < reserves.length; i++) {
            uint256 amount = dGetNumeraireBalance(reserves[i]);
            uint256 proportionateValue = wmul(wmul(amount, _withdrawMultiplier), WAD - feeBase);
            Flavor memory _f = flavors[numeraires[i]];
            withdrawalAmts_[i] = dOutputNumeraire(_f.adapter, msg.sender, proportionateValue);
        }

        emit ShellsBurned(msg.sender, _withdrawal, numeraires, withdrawalAmts_);

        return withdrawalAmts_;

    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");
        balances[account] = sub(balances[account], amount);
        totalSupply = sub(totalSupply, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");
        totalSupply = add(totalSupply, amount);
        balances[account] = add(balances[account], amount);
    }

}