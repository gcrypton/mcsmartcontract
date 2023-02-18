// SPDX-License-Identifier: Unlicensed

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IBEP20 {
  /**
   * @dev Emitted when `value` tokens are moved from one account (`from`) to
   * another (`to`).
   *
   * Note that `value` may be zero.
   */
  event Transfer(address indexed from, address indexed to, uint256 value);

  /**
   * @dev Emitted when the allowance of a `spender` for an `owner` is set by
   * a call to {approve}. `value` is the new allowance.
   */
  event Approval(address indexed owner, address indexed spender, uint256 value);

  /**
   * @dev Returns the amount of tokens in existence.
   */
  function totalSupply() external view returns (uint256);

  /**
   * @dev Returns the amount of tokens owned by `account`.
   */
  function balanceOf(address account) external view returns (uint256);

  /**
   * @dev Moves `amount` tokens from the caller's account to `to`.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * Emits a {Transfer} event.
   */
  function transfer(address to, uint256 amount) external returns (bool);

  /**
   * @dev Returns the remaining number of tokens that `spender` will be
   * allowed to spend on behalf of `owner` through {transferFrom}. This is
   * zero by default.
   *
   * This value changes when {approve} or {transferFrom} are called.
   */
  function allowance(address owner, address spender) external view returns (uint256);

  /**
   * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * IMPORTANT: Beware that changing an allowance with this method brings the risk
   * that someone may use both the old and the new allowance by unfortunate
   * transaction ordering. One possible solution to mitigate this race
   * condition is to first reduce the spender's allowance to 0 and set the
   * desired value afterwards:
   * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
   *
   * Emits an {Approval} event.
   */
  function approve(address spender, uint256 amount) external returns (bool);

  /**
   * @dev Moves `amount` tokens from `from` to `to` using the
   * allowance . `amount` is then deducted from the caller's
   * allowance.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * Emits a {Transfer} event.
   */
  function transferFrom(
    address from,
    address to,
    uint256 amount
  ) external returns (bool);
}

pragma solidity ^0.8.0;

contract MultisigTimelock {
    uint constant MINIMUM_DELAY = 48 hours;
    uint constant MAXIMUM_DELAY = 7 days;
    uint constant GRACE_PERIOD = 7 days;
    uint public constant CONFIRMATIONS_REQUIRED = 2;
    uint public constant OWNERS_REQUIRED = 3;

    address[] public owners;
    mapping(address => bool) public isOwner;

    struct Transaction {
        bytes32 uid;
        address to;
        uint value;
        bytes data;
        bool executed;
        uint confirmations;
    }
    mapping(bytes32 => Transaction) public txs;

    mapping(bytes32 => mapping(address => bool)) public confirmations;

    mapping(bytes32 => bool) public queue;

    modifier onlyOwner() {
        require(isOwner[msg.sender], "not an owner!");
        _;
    }

    event Queued(bytes32 txId);
    event Discarded(bytes32 txId);
    event Executed(bytes32 txId);

    constructor(address[] memory _owners) {
        require(_owners.length == OWNERS_REQUIRED, "not enough owners!");

        for(uint i = 0; i < _owners.length; i++) {
            address nextOwner = _owners[i];

            require(nextOwner != address(0), "cant have zero address as owner!");
            require(!isOwner[nextOwner], "duplicate owner!");

            isOwner[nextOwner] = true;
            owners.push(nextOwner);
        }
    }

    function addToQueue(
        address _to,
        string calldata _func,
        bytes calldata _data,
        uint _value,
        uint _timestamp
    ) external onlyOwner returns(bytes32) {
        require(
            _timestamp > block.timestamp + MINIMUM_DELAY &&
            _timestamp < block.timestamp + MAXIMUM_DELAY,
            "invalid timestamp"
        );
        bytes32 txId = keccak256(abi.encode(
            _to,
            _func,
            _data,
            _value,
            _timestamp
        ));

        require(!queue[txId], "already queued");

        queue[txId] = true;

        txs[txId] = Transaction({
            uid: txId,
            to: _to,
            value: _value,
            data: _data,
            executed: false,
            confirmations: 0
        });

        emit Queued(txId);

        return txId;
    }

    function confirm(bytes32 _txId) external onlyOwner {
        require(queue[_txId], "not queued!");
        require(!confirmations[_txId][msg.sender], "already confirmed!");

        Transaction storage transaction = txs[_txId];

        transaction.confirmations++;
        confirmations[_txId][msg.sender] = true;
    }


    function cancelConfirmation(bytes32 _txId) external onlyOwner {
        require(queue[_txId], "not queued!");
        require(confirmations[_txId][msg.sender], "not confirmed!");

        Transaction storage transaction = txs[_txId];
        transaction.confirmations--;
        confirmations[_txId][msg.sender] = false;
    }

    function execute(
        address _to,
        string calldata _func,
        bytes calldata _data,
        uint _value,
        uint _timestamp
    ) external payable onlyOwner returns(bytes memory) {
        require(
            block.timestamp > _timestamp,
            "too early"
        );
        require(
            _timestamp + GRACE_PERIOD > block.timestamp,
            "tx expired"
        );

        bytes32 txId = keccak256(abi.encode(
            _to,
            _func,
            _data,
            _value,
            _timestamp
        ));

        require(queue[txId], "not queued!");

        Transaction storage transaction = txs[txId];

        require(transaction.confirmations >= CONFIRMATIONS_REQUIRED &&
         !transaction.executed, "not enough confirmations!");

        delete queue[txId];

        transaction.executed = true;

        bytes memory data;
        if(bytes(_func).length > 0) {
            data = abi.encodePacked(
                bytes4(keccak256(bytes(_func))),
                _data
            );
        } else {
            data = _data;
        }

        (bool success, bytes memory resp) = _to.call{value: _value}(data);
        require(success);

        emit Executed(txId);
        return resp;
    }

    function discard(bytes32 _txId) external onlyOwner {
        require(queue[_txId], "not queued");

        delete queue[_txId];

        emit Discarded(_txId);
    }
}

contract paymentManager{
  address public timelock;

  bool public paused;
  IBEP20 public busd = IBEP20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

  event BUSD_Transfer(address _to, uint256 _amount);
  event ETH_Transfer(address _to, uint256 _amount);
  event Paused_Status(bool _paused);
  event AdminUpdated(address _newAdmin);

  constructor(address _timelock) {
    timelock = _timelock;
  }
  /**
   * @dev Throws if called by any account other than the timelock.
   */
  modifier onlyTimelock() {
    require(timelock == msg.sender, "caller is not the timelock");
    _;
  }

  receive() external payable {}

  /**
   * @dev timelock can pause/resume admin executions.
   */
  function togglePaused() external onlyTimelock {
    paused = !paused;

    emit Paused_Status(paused);
  }

  /**
   * @dev if not paused by timelock, timelock can transfer an amount of contract busd balance to address.
   */
  function busdTransfer(address _to, uint256 _amount) external onlyTimelock {
    require(!paused, "paused!");
    busd.transfer(_to, _amount);

    emit BUSD_Transfer(_to, _amount);
  }

  /**
   * @dev if not paused by timelock, timelock can transfer an amount of contract Eth balance to address.
   */
  function ethTransfer(address _to, uint256 _amount) external onlyTimelock {
    require(!paused, "paused!");
    (bool success, ) = payable(_to).call{gas: 50000, value: _amount}("");
    require(success);

    emit ETH_Transfer(_to, _amount);
  }

  /**
   * @dev timelock will be able to withdraw any stucked token balance within the contract to an address.
   */
  function withdrawToken(
    address _token,
    uint256 _amount,
    address _to
  ) external onlyTimelock {
    IBEP20(_token).transfer(_to, _amount);
  }
}