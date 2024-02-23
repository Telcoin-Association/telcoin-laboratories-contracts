# Solidity API

## TelcoinDistributor

A Telcoin Laboratories Contract
This is a Safe Wallet module that allows a proposer to propose a transaction that can be vetoed by any challenger within a challenge period.

### TELCOIN

```solidity
contract IERC20 TELCOIN
```

### councilNft

```solidity
contract IERC721 councilNft
```

### challengePeriod

```solidity
uint256 challengePeriod
```

### proposedTransactions

```solidity
struct TelcoinDistributor.ProposedTransaction[] proposedTransactions
```

### ProposedTransaction

```solidity
struct ProposedTransaction {
  uint256 totalWithdrawl;
  address[] destinations;
  uint256[] amounts;
  uint64 timestamp;
  bool challenged;
  bool executed;
}
```

### TransactionProposed

```solidity
event TransactionProposed(uint256 transactionId, address proposer)
```

### TransactionChallenged

```solidity
event TransactionChallenged(uint256 transactionId, address challenger)
```

### ChallengePeriodUpdated

```solidity
event ChallengePeriodUpdated(uint256 newPeriod)
```

### constructor

```solidity
constructor(contract IERC20 telcoin, uint256 period, contract IERC721 council) public
```

Constructs a new instance of the TelcoinDistributor contract

_Assigns the challenge period, and council NFT provided as parameters_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| telcoin | contract IERC20 | telcoin address |
| period | uint256 | the period during which a proposed transaction can be challenged |
| council | contract IERC721 | the NFT that will be used to determine if an account is a proposer or challenger |

### proposeTransaction

```solidity
function proposeTransaction(uint256 totalWithdrawl, address[] destinations, uint256[] amounts) external
```

Proposes a new transaction to be added to the queue

_The function checks if the sender is a proposer before allowing the transaction proposal
A transaction proposed can be challenged during the challenge period
A pausable function_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| totalWithdrawl | uint256 | total amount of Telcoin to be taken from safe |
| destinations | address[] | locations of Telcoin dispursals |
| amounts | uint256[] | amounts of Telcoin to be sent |

### challengeTransaction

```solidity
function challengeTransaction(uint256 transactionId) external
```

Allows a challenger to challenge a proposed transaction

_The function reverts if the caller is not a challenger, the transaction timestamp is invalid,
or the challenge period has expired. It sets the transaction's challenged flag to true if successful.
A pausable function_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| transactionId | uint256 | the ID of the transaction to challenge |

### executeTransaction

```solidity
function executeTransaction(uint256 transactionId) external
```

Execute transaction

_A pausable function_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| transactionId | uint256 | the transaction ID. |

### batchTelcoin

```solidity
function batchTelcoin(uint256 totalWithdrawl, address[] destinations, uint256[] amounts) internal
```

sends Telcoin in batches

_must first approve contract for balance
if there is not a zero difference balance at the end of the transaction the transaction will revert_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| totalWithdrawl | uint256 | the total amount of tokens to be send |
| destinations | address[] | an array of destinations |
| amounts | uint256[] | an array of send values |

### setChallengePeriod

```solidity
function setChallengePeriod(uint256 newPeriod) public
```

Updates the challenge period for transactions

_Only the owner contract can call this function_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newPeriod | uint256 | the updated period |

### recoverERC20

```solidity
function recoverERC20(contract IERC20 tokenAddress, uint256 tokenAmount, address to) external
```

Recover ERC20 tokens from THIS contract

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokenAddress | contract IERC20 | ERC20 token contract |
| tokenAmount | uint256 | amount of tokens to recover |
| to | address | account to send the recovered tokens to |

### pause

```solidity
function pause() external
```

_Triggers stopped state_

### unpause

```solidity
function unpause() external
```

_Returns to normal state_

### onlyCouncilMember

```solidity
modifier onlyCouncilMember()
```

Checks if an account is a Council Member

## CouncilMember

A Telcoin Laboratories Contract
A contract to signify ownership council membership

_Relies on OpenZeppelin's open source smart contracts_

### ProxyUpdated

```solidity
event ProxyUpdated(contract IPRBProxy newProxy)
```

### LockupUpdated

```solidity
event LockupUpdated(contract ISablierV2Lockup newLockup)
```

### TargetUpdated

```solidity
event TargetUpdated(address newTarget)
```

### IDUpdated

```solidity
event IDUpdated(uint256 newID)
```

### TELCOIN

```solidity
contract IERC20 TELCOIN
```

### _proxy

```solidity
contract IPRBProxy _proxy
```

### _target

```solidity
address _target
```

### _lockup

```solidity
contract ISablierV2Lockup _lockup
```

### _id

```solidity
uint256 _id
```

### balances

```solidity
uint256[] balances
```

### tokenIdToBalanceIndex

```solidity
mapping(uint256 => uint256) tokenIdToBalanceIndex
```

### balanceIndexToTokenId

```solidity
mapping(uint256 => uint256) balanceIndexToTokenId
```

### GOVERNANCE_COUNCIL_ROLE

```solidity
bytes32 GOVERNANCE_COUNCIL_ROLE
```

### SUPPORT_ROLE

```solidity
bytes32 SUPPORT_ROLE
```

### initialize

```solidity
function initialize(contract IERC20 telcoin, string name_, string symbol_, contract IPRBProxy proxy_, address target_, contract ISablierV2Lockup lockup_, uint256 id_) external
```

### retrieve

```solidity
function retrieve() external
```

Allows authorized personnel to retrieve and distribute TELCOIN to council members

_The main logic behind the TELCOIN distribution is encapsulated in this function.
This function should be called before any significant state changes to ensure accurate distribution.
Only the owner council members can call this function_

### claim

```solidity
function claim(uint256 tokenId, uint256 amount) external
```

Allows council members to claim their allocated amounts of TELCOIN

_Checks if the caller is the owner of the provided tokenId and if the requested amount is available._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokenId | uint256 | The NFT index associated with a council member. |
| amount | uint256 | Amount of TELCOIN the council member wants to withdraw. |

### transferFrom

```solidity
function transferFrom(address from, address to, uint256 tokenId) public
```

Replace an existing council member with a new one and withdraws the old member's TELCOIN allocation

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| from | address | Address of the current council member to be replaced. |
| to | address | Address of the new council member. |
| tokenId | uint256 | Token ID of the council member NFT. |

### supportsInterface

```solidity
function supportsInterface(bytes4 interfaceId) public pure returns (bool)
```

Check if the contract supports a specific interface

_Overrides the supportsInterface function from OpenZeppelin._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| interfaceId | bytes4 | ID of the interface to check for support. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True if the contract supports the interface, false otherwise. |

### approve

```solidity
function approve(address to, uint256 tokenId) public
```

Approve a specific address for a specific NFT

_Overrides the approve function from ERC721.
Restricted to the GOVERNANCE_COUNCIL_ROLE._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| to | address | Address to be approved. |
| tokenId | uint256 | Token ID of the NFT to be approved. |

### removeApproval

```solidity
function removeApproval(uint256 tokenId) public
```

removes approval a specific address for a specific NFT

_Restricted to the GOVERNANCE_COUNCIL_ROLE._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokenId | uint256 | Token ID of the NFT to be approved. |

### setApprovalForAll

```solidity
function setApprovalForAll(address, bool) public
```

### mint

```solidity
function mint(address newMember) external
```

Mint new council member NFTs

_This function also retrieves and distributes TELCOIN.
Restricted to the GOVERNANCE_COUNCIL_ROLE._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| newMember | address | Address of the new council member. |

### burn

```solidity
function burn(uint256 tokenId, address recipient) external
```

Burn a council member NFT

_The function retrieves and distributes TELCOIN before burning the NFT.
Restricted to the GOVERNANCE_COUNCIL_ROLE._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokenId | uint256 | Token ID of the council member NFT to be burned. |
| recipient | address | Address to receive the burned NFT holder's TELCOIN allocation. |

### updateProxy

```solidity
function updateProxy(contract IPRBProxy proxy_) external
```

Update the stream proxy address

_Restricted to the GOVERNANCE_COUNCIL_ROLE._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| proxy_ | contract IPRBProxy | New stream proxy address. |

### updateTarget

```solidity
function updateTarget(address target_) external
```

Update the target address

_Restricted to the GOVERNANCE_COUNCIL_ROLE._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target_ | address | New target address. |

### updateLockup

```solidity
function updateLockup(contract ISablierV2Lockup lockup_) external
```

Update the lockup address

_Restricted to the GOVERNANCE_COUNCIL_ROLE._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| lockup_ | contract ISablierV2Lockup | New lockup address. |

### updateID

```solidity
function updateID(uint256 id_) external
```

Update the ID for a council member

_Restricted to the GOVERNANCE_COUNCIL_ROLE._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| id_ | uint256 | New ID for the council member. |

### _retrieve

```solidity
function _retrieve() internal
```

Retrieve and distribute TELCOIN to council members based on the stream from _target

_This function fetches the maximum possible TELCOIN and distributes it equally among all council members.
It also updates the running balance to ensure accurate distribution during subsequent calls._

### _isAuthorized

```solidity
function _isAuthorized(address, address spender, uint256 tokenId) internal view returns (bool)
```

Determines if an address is approved or is the owner for a specific token ID

_This function checks if the spender has GOVERNANCE_COUNCIL_ROLE or is the approved address for the token._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
|  | address |  |
| spender | address | Address to check approval or ownership for. |
| tokenId | uint256 | Token ID to check against. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True if the address is approved or is the owner, false otherwise. |

### _update

```solidity
function _update(address to, uint256 tokenId, address auth) internal returns (address)
```

Handle operations to be performed before transferring a token

_This function retrieves and distributes TELCOIN before the token transfer.
It is an override of the _beforeTokenTransfer from OpenZeppelin's ERC721._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| to | address | Address from which the token is being transferred. |
| tokenId | uint256 | Token ID that's being transferred. |
| auth | address | Token ID that's being transferred. |

### erc20Rescue

```solidity
function erc20Rescue(contract IERC20 token, address destination, uint256 amount) external
```

Rescues any ERC20 token sent accidentally to the contract

_Only addresses with the SUPPORT_ROLE can call this function._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| token | contract IERC20 | ERC20 token address which needs to be rescued. |
| destination | address | Address where the tokens will be sent. |
| amount | uint256 | Amount of tokens to be transferred. |

### OnlyAuthorized

```solidity
modifier OnlyAuthorized()
```

Checks if the caller is authorized either by being a council member or having the GOVERNANCE_COUNCIL_ROLE

_This modifier is used to restrict certain operations to council members or governance personnel._

## IPRBProxy

Proxy contract to compose transactions on behalf of the owner.

### execute

```solidity
function execute(address target, bytes data) external payable returns (bytes response)
```

Delegate calls to the provided target contract by forwarding the data. It returns the data it
gets back, and bubbles up any potential revert.

_Emits an {Execute} event.

Requirements:
- The caller must be either the owner or an envoy with permission.
- `target` must be a contract._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| target | address | The address of the target contract. |
| data | bytes | Function selector plus ABI encoded data. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| response | bytes | The response received from the target contract, if any. |

## ISablierV2Lockup

## ISablierV2ProxyTarget

Proxy target with stateless scripts for interacting with Sablier V2, designed to be used by
stream senders.

_Intended for use with an instance of PRBProxy through delegate calls. Any standard calls will be reverted._

### withdrawMax

```solidity
function withdrawMax(contract ISablierV2Lockup lockup, uint256 streamId, address to) external
```

Mirror for {ISablierV2Lockup.withdrawMax}.

_Must be delegate called._

## TestProxy

### _token

```solidity
contract IERC20 _token
```

### lastBlock

```solidity
uint256 lastBlock
```

### constructor

```solidity
constructor(contract IERC20 token_) public
```

### execute

```solidity
function execute(address, bytes) external payable returns (bytes response)
```

## BalancerAdaptor

A Telcoin Laboratories Contract
A contract to calculate the voting weight based on Telcoin held by an address, considering both direct balance and equivalent in specified sources.

### TELCOIN

```solidity
contract IERC20 TELCOIN
```

### _valut

```solidity
contract IBalancerVault _valut
```

### _poolId

```solidity
bytes32 _poolId
```

### _pool

```solidity
contract IBalancerPool _pool
```

### _mFactor

```solidity
uint256 _mFactor
```

### _dFactor

```solidity
uint256 _dFactor
```

### constructor

```solidity
constructor(contract IERC20 telcoin, contract IBalancerVault vault_, bytes32 poolId_, contract IBalancerPool pool_, uint256 mFactor_, uint256 dFactor_) public
```

### supportsInterface

```solidity
function supportsInterface(bytes4 interfaceId) external pure returns (bool)
```

Returns if is valid interface

_Override for supportsInterface to adhere to IERC165 standard_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| interfaceId | bytes4 | bytes representing the interface |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | bool confirmation of matching interfaces |

### balanceOf

```solidity
function balanceOf(address voter) external view returns (uint256)
```

Calculates the voting weight of a voter

_gets pool share equivalent of the amount of Telcoin in the pool_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| voter | address | the address being evaluated |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | uint256 Total voting weight of the voter |

## StakingModuleAdaptor

A Telcoin Laboratories Contract
A contract to calculate the voting weight based on Telcoin held by an address, considering both direct balance and equivalent in specified sources.

### _module

```solidity
contract IStakingModule _module
```

### constructor

```solidity
constructor(contract IStakingModule module_) public
```

### supportsInterface

```solidity
function supportsInterface(bytes4 interfaceId) external pure returns (bool)
```

Returns if is valid interface

_Override for supportsInterface to adhere to IERC165 standard_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| interfaceId | bytes4 | bytes representing the interface |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | bool confirmation of matching interfaces |

### balanceOf

```solidity
function balanceOf(address voter) external view returns (uint256)
```

Calculates the voting weight of a voter

_gets pool share equivalent of the amount of Telcoin in the pool_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| voter | address | the address being evaluated |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | uint256 Total voting weight of the voter |

## StakingRewardsAdaptor

A Telcoin Laboratories Contract
A contract to calculate the voting weight based on Telcoin held by an address, considering both direct balance and equivalent in specified sources.

### _staking

```solidity
contract IStakingRewards _staking
```

### _source

```solidity
contract ISource _source
```

### constructor

```solidity
constructor(contract ISource source_, contract IStakingRewards staking_) public
```

### supportsInterface

```solidity
function supportsInterface(bytes4 interfaceId) external pure returns (bool)
```

Returns if is valid interface

_Override for supportsInterface to adhere to IERC165 standard_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| interfaceId | bytes4 | bytes representing the interface |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | bool confirmation of matching interfaces |

### balanceOf

```solidity
function balanceOf(address voter) external view returns (uint256)
```

Calculates the voting weight of a voter

_gets pool share equivalent of the amount of Telcoin in the pool_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| voter | address | the address being evaluated |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | uint256 Total voting weight of the voter |

## VotingWeightCalculator

A Telcoin Laboratories Contract
A contract to calculate the voting weight based on Telcoin held by an address, considering both direct balance and equivalent in specified sources.

_Relies on OpenZeppelin's Ownable2Step for ownership control and other external interfaces for token_

### sources

```solidity
contract ISource[] sources
```

### constructor

```solidity
constructor(address initialOwner) public
```

### addSource

```solidity
function addSource(address source) external
```

Adds a new soure to be considered when calculating voting weight.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| source | address | liquidity source to be added |

### removeSource

```solidity
function removeSource(uint256 index) external
```

Removes a token source from the list.

_It replaces the source to be removed with the last source in the array, then removes the last source._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| index | uint256 | index of the source to be removed. |

### balanceOf

```solidity
function balanceOf(address voter) public view returns (uint256 runningTotal)
```

Calculates the total voting weight of a voter.

_Voting weight includes direct Telcoin balance and equivalent balance in whitelisted sources and staking contract._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| voter | address | the address being evaluated |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| runningTotal | uint256 | Total voting weight of the voter. |

## IBalancerPool

### balanceOf

```solidity
function balanceOf(address account) external view returns (uint256)
```

### totalSupply

```solidity
function totalSupply() external view returns (uint256)
```

## IBalancerVault

### getPoolTokenInfo

```solidity
function getPoolTokenInfo(bytes32 poolId, contract IERC20 token) external view returns (uint256 cash, uint256 managed, uint256 lastChangeBlock, address assetManager)
```

## ISource

### balanceOf

```solidity
function balanceOf(address voter) external view returns (uint256)
```

## IStakingModule

### balanceOf

```solidity
function balanceOf(address account, bytes auxData) external view returns (uint256)
```

## IStakingRewards

### earned

```solidity
function earned(address account) external view returns (uint256)
```

### balanceOf

```solidity
function balanceOf(address account) external view returns (uint256)
```

### totalSupply

```solidity
function totalSupply() external view returns (uint256)
```

## RewardsDistributionRecipient

This abstract contract allows for distribution of rewards in the contract.
It defines functionality for setting the address of the rewards distribution contract
and a function to notify the reward amount which must be implemented by inheriting contracts.
It also has a modifier to restrict functions to being called only from the rewards distribution contract.

_Inherits from the Ownable contract from OpenZeppelin to provide basic access control._

### rewardsDistribution

```solidity
address rewardsDistribution
```

### notifyRewardAmount

```solidity
function notifyRewardAmount(uint256 reward) external virtual
```

Notify about the reward amount

_Function that contracts inheriting from RewardsDistributionRecipient need to implement._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| reward | uint256 | The amount of the reward to distribute |

### onlyRewardsDistribution

```solidity
modifier onlyRewardsDistribution()
```

Modifier to allow only the rewards distribution contract to call certain functions

_If the function is called by any address other than the rewards distribution contract, the transaction is reverted._

### setRewardsDistribution

```solidity
function setRewardsDistribution(address rewardsDistribution_) external
```

Set the rewards distribution contract

_Can only be called by the owner of the contract. Updates the rewardsDistribution address._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| rewardsDistribution_ | address | The address of the new rewards distribution contract |

### RewardsDistributionUpdated

```solidity
event RewardsDistributionUpdated(address newDistribution)
```

## StakingRewards

This contract handles staking and rewards for a particular token.
It inherits functionality from RewardsDistributionRecipient, ReentrancyGuard, and Pausable contracts.

### rewardsToken

```solidity
contract IERC20 rewardsToken
```

### stakingToken

```solidity
contract IERC20 stakingToken
```

### periodFinish

```solidity
uint256 periodFinish
```

### rewardRate

```solidity
uint256 rewardRate
```

### rewardsDuration

```solidity
uint256 rewardsDuration
```

### lastUpdateTime

```solidity
uint256 lastUpdateTime
```

### rewardPerTokenStored

```solidity
uint256 rewardPerTokenStored
```

### userRewardPerTokenPaid

```solidity
mapping(address => uint256) userRewardPerTokenPaid
```

### rewards

```solidity
mapping(address => uint256) rewards
```

### EQUALIZING_FACTOR

```solidity
uint256 EQUALIZING_FACTOR
```

### constructor

```solidity
constructor(address rewardsDistribution_, contract IERC20 rewardsToken_, contract IERC20 stakingToken_) public
```

Constructor to set initial state variables.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| rewardsDistribution_ | address | The address of the rewards distribution contract. |
| rewardsToken_ | contract IERC20 | The address of the rewards token contract. |
| stakingToken_ | contract IERC20 | The address of the staking token contract. |

### totalSupply

```solidity
function totalSupply() external view returns (uint256)
```

Returns total supply of the staking tokens.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Total supply of the staking tokens. |

### balanceOf

```solidity
function balanceOf(address account) external view returns (uint256)
```

Returns balance of the staking tokens for a given account.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| account | address | The address of the account. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Balance of the staking tokens for the account. |

### lastTimeRewardApplicable

```solidity
function lastTimeRewardApplicable() public view returns (uint256)
```

Returns the last timestamp where rewards were applicable.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Last timestamp where rewards were applicable. |

### rewardPerToken

```solidity
function rewardPerToken() public view returns (uint256)
```

Calculates the amount of reward per staked token.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The amount of reward per staked token. |

### earned

```solidity
function earned(address account) public view returns (uint256)
```

Calculates the earned rewards of an account.

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| account | address | The address of the account. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The earned rewards of the account. |

### getRewardForDuration

```solidity
function getRewardForDuration() external view returns (uint256)
```

Calculates the rewards for the reward duration.

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The rewards for the reward duration. |

### stake

```solidity
function stake(uint256 amount) external
```

Stake a certain amount of tokens.

_This function is protected by the nonReentrant modifier to prevent double spending._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amount | uint256 | The amount of tokens to stake. |

### withdraw

```solidity
function withdraw(uint256 amount) public
```

Withdraw a certain amount of tokens.

_This function is protected by the nonReentrant modifier to prevent double spending._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| amount | uint256 | The amount of tokens to withdraw. |

### getReward

```solidity
function getReward() public
```

Get the earned rewards of the caller.

_This function is protected by the nonReentrant modifier to prevent double spending._

### exit

```solidity
function exit() external
```

Withdraw all tokens and get the earned rewards for the caller.

### notifyRewardAmount

```solidity
function notifyRewardAmount(uint256 reward) external
```

Notify the contract about the reward amount for the next period

_It's an overridden function, which can only be called by the reward distribution address_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| reward | uint256 | The amount of reward for the next period |

### recoverERC20

```solidity
function recoverERC20(address destination, contract IERC20 tokenAddress, uint256 tokenAmount) external
```

Recover ERC20 tokens which are sent by mistake to this contract

_This can only be done by the contract owner_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| destination | address | The address to which the tokens will be sent |
| tokenAddress | contract IERC20 | The address of the token to recover |
| tokenAmount | uint256 | The amount of tokens to recover |

### setRewardsDuration

```solidity
function setRewardsDuration(uint256 rewardsDuration_) external
```

Update the duration of the rewards

_This can only be done by the contract owner_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| rewardsDuration_ | uint256 | The new duration of the rewards |

### updateReward

```solidity
modifier updateReward(address account)
```

Update the reward of the account

_It's used in several external functions to calculate and update the rewards_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| account | address | The address of the account |

### RewardAdded

```solidity
event RewardAdded(uint256 reward)
```

### Staked

```solidity
event Staked(address user, uint256 amount)
```

### Withdrawn

```solidity
event Withdrawn(address user, uint256 amount)
```

### RewardPaid

```solidity
event RewardPaid(address user, uint256 reward)
```

### RewardsDurationUpdated

```solidity
event RewardsDurationUpdated(uint256 newDuration)
```

### Recovered

```solidity
event Recovered(contract IERC20 token, uint256 amount)
```

## StakingRewardsFactory

A Telcoin Contract
This contract creates and keeps track of instances of StakingRewards contracts.

_Implements Openzeppelin Audited Contracts_

### stakingRewardsImplementation

```solidity
address stakingRewardsImplementation
```

### stakingRewardsContracts

```solidity
contract StakingRewards[] stakingRewardsContracts
```

### NewStakingRewardsContract

```solidity
event NewStakingRewardsContract(uint256 index, contract IERC20 rewardToken, contract IERC20 stakingToken, contract StakingRewards implementation)
```

### constructor

```solidity
constructor(address implementation) public
```

### createStakingRewards

```solidity
function createStakingRewards(address rewardsDistribution, contract IERC20 rewardsToken, contract IERC20 stakingToken) external returns (contract StakingRewards)
```

Creates a new StakingRewards contract

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| rewardsDistribution | address | The address of the rewards distribution contract. |
| rewardsToken | contract IERC20 | The address of the rewards token contract. |
| stakingToken | contract IERC20 | The address of the staking token contract. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | contract StakingRewards | The address of the newly created StakingRewards contract |

### getStakingRewardsContract

```solidity
function getStakingRewardsContract(uint256 index) external view returns (contract StakingRewards)
```

Get the address of the StakingRewards contract at a given index

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| index | uint256 | The index of the StakingRewards contract |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | contract StakingRewards | The address of the StakingRewards contract |

### getStakingRewardsContractCount

```solidity
function getStakingRewardsContractCount() public view returns (uint256)
```

Get the total number of StakingRewards contracts created by this factory

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of StakingRewards contracts |

## StakingRewardsManager

A Telcoin Contract
This contract can manage multiple Synthetix StakingRewards contracts.
Staking contracts managed my multisigs can avoid having to coordinate to top up contracts every staking period.
Instead, add staking contracts to this manager contract, approve this contract to spend the rewardToken and then topUp() can be called permissionlessly.

_Implements Openzeppelin Audited Contracts_

### BUILDER_ROLE

```solidity
bytes32 BUILDER_ROLE
```

This role grants the ability to rescue ERC20 tokens that do not rightfully belong to this contract

### MAINTAINER_ROLE

```solidity
bytes32 MAINTAINER_ROLE
```

### SUPPORT_ROLE

```solidity
bytes32 SUPPORT_ROLE
```

### ADMIN_ROLE

```solidity
bytes32 ADMIN_ROLE
```

### EXECUTOR_ROLE

```solidity
bytes32 EXECUTOR_ROLE
```

### StakingConfig

_StakingRewards config_

```solidity
struct StakingConfig {
  uint256 rewardsDuration;
  uint256 rewardAmount;
}
```

### rewardToken

```solidity
contract IERC20 rewardToken
```

_Reward token for all StakingRewards contracts managed by this contract_

### stakingRewardsFactory

```solidity
contract StakingRewardsFactory stakingRewardsFactory
```

_Optional factory contract for creating new StakingRewards contracts_

### stakingContracts

```solidity
contract StakingRewards[] stakingContracts
```

_Array of managed StakingRewards contracts_

### stakingExists

```solidity
mapping(contract StakingRewards => bool) stakingExists
```

_Maps a StakingReward contract to boolean indicating its existence in the stakingContracts array_

### stakingConfigs

```solidity
mapping(contract StakingRewards => struct StakingRewardsManager.StakingConfig) stakingConfigs
```

_Maps a StakingReward contract to its configuration (rewardsDuration and rewardAmount)_

### StakingAdded

```solidity
event StakingAdded(contract StakingRewards staking, struct StakingRewardsManager.StakingConfig config)
```

_Emitted when an existing StakingRewards contract is added to the stakingContracts array_

### StakingRemoved

```solidity
event StakingRemoved(contract StakingRewards staking)
```

_Emitted when a StakingRewards contract is removed from the stakingContracts array_

### StakingConfigChanged

```solidity
event StakingConfigChanged(contract StakingRewards staking, struct StakingRewardsManager.StakingConfig config)
```

_Emitted when configuration for a StakingRewards contract is changed_

### StakingRewardsFactoryChanged

```solidity
event StakingRewardsFactoryChanged(contract StakingRewardsFactory stakingFactory)
```

_Emitted when the StakingRewards Factory contract is changed_

### PeriodFinishUpdated

```solidity
event PeriodFinishUpdated(contract StakingRewards staking, uint256 newPeriodFinish)
```

_Emitted when updatePeriodFinish is called on a StakingRewards contract_

### ToppedUp

```solidity
event ToppedUp(contract StakingRewards staking, struct StakingRewardsManager.StakingConfig config)
```

_Emitted when a StakingRewards contract is topped up_

### initialize

```solidity
function initialize(contract IERC20 reward, contract StakingRewardsFactory factory) external
```

initialize the contract

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| reward | contract IERC20 | The reward token of all the managed staking contracts |
| factory | contract StakingRewardsFactory |  |

### stakingContractsLength

```solidity
function stakingContractsLength() external view returns (uint256)
```

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | length uint256 of stakingContracts array |

### getStakingContract

```solidity
function getStakingContract(uint256 i) external view returns (contract StakingRewards)
```

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | contract StakingRewards | length uint256 of stakingContracts array |

### createNewStakingRewardsContract

```solidity
function createNewStakingRewardsContract(contract IERC20 stakingToken, struct StakingRewardsManager.StakingConfig config) external
```

Create a new StakingRewards contract via the factory and add it to the stakingContracts array of managed contracts

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| stakingToken | contract IERC20 | Staking token for the new StakingRewards contract |
| config | struct StakingRewardsManager.StakingConfig | Staking configuration |

### addStakingRewardsContract

```solidity
function addStakingRewardsContract(contract StakingRewards staking, struct StakingRewardsManager.StakingConfig config) external
```

Add a StakingRewards contract

_This contract must be nominated for ownership before the staking contract can be added
If this contract cannot acceptOwnership of the staking contract this function will revert
This function WILL NOT REVERT if `staking` does not have the right rewardToken.
Do not add staking contracts with rewardToken other than the one passed to initialize this contract._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| staking | contract StakingRewards | Address of the StakingRewards contract to add |
| config | struct StakingRewardsManager.StakingConfig | Configuration of the staking contracts |

### _addStakingRewardsContract

```solidity
function _addStakingRewardsContract(contract StakingRewards staking, struct StakingRewardsManager.StakingConfig config) internal
```

Add a StakingRewards contract

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| staking | contract StakingRewards | Address of the StakingRewards contract to add |
| config | struct StakingRewardsManager.StakingConfig | Configuration of the staking contracts |

### removeStakingRewardsContract

```solidity
function removeStakingRewardsContract(uint256 i) external
```

Remove a StakingRewards contract from the stakingContracts array. This will remove this contract's ability to manage it

_This function WILL NOT transfer ownership of the staking contract. To do this, call `nominateOwnerForStaking`_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| i | uint256 | Index of staking contract to remove |

### setStakingConfig

```solidity
function setStakingConfig(contract StakingRewards staking, struct StakingRewardsManager.StakingConfig config) external
```

Set the configuration for a StakingRewards contract

_`staking` does not need to be included in `stakingContracts` for this function to succeed_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| staking | contract StakingRewards | Address of StakingRewards contract |
| config | struct StakingRewardsManager.StakingConfig | Staking config |

### setStakingRewardsFactory

```solidity
function setStakingRewardsFactory(contract StakingRewardsFactory factory) external
```

Set the StakingRewards Factory contract

_Factory AND StakingRewards contracts must maintain their ABI_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| factory | contract StakingRewardsFactory | Address of StakingRewards Factory contract |

### recoverERC20FromStaking

```solidity
function recoverERC20FromStaking(contract StakingRewards staking, contract IERC20 tokenAddress, uint256 tokenAmount, address to) external
```

Recover ERC20 tokens from a StakingRewards contract

_This contract must own the staking contract_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| staking | contract StakingRewards | The staking contract to recover tokens from |
| tokenAddress | contract IERC20 | Address of the ERC20 token contract |
| tokenAmount | uint256 | Amount of tokens to recover |
| to | address | The account to send the recovered tokens to |

### recoverTokens

```solidity
function recoverTokens(contract IERC20 tokenAddress, uint256 tokenAmount, address to) external
```

Recover ERC20 tokens from THIS contract

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| tokenAddress | contract IERC20 | Address of the ERC20 token contract |
| tokenAmount | uint256 | Amount of tokens to recover |
| to | address | The account to send the recovered tokens to |

### transferStakingOwnership

```solidity
function transferStakingOwnership(contract StakingRewards staking, address newOwner) external
```

change ownership for a staking contract

_This contract must currently own the staking contract_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| staking | contract StakingRewards | The staking contract to transfer ownership of |
| newOwner | address | Account of new owner |

### topUp

```solidity
function topUp(address source, uint256[] indices) external
```

Top up multiple staking contracts

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| source | address | address from which tokens are taken |
| indices | uint256[] | array of staking contract indices |

## TestNFT

### constructor

```solidity
constructor() public
```

### mint

```solidity
function mint(address to, uint256 tokenId) public
```

## TestTelcoin

### constructor

```solidity
constructor(address recipient) public
```

### decimals

```solidity
function decimals() public pure returns (uint8)
```

_Returns the number of decimals used to get its user representation.
For example, if `decimals` equals `2`, a balance of `505` tokens should
be displayed to a user as `5.05` (`505 / 10 ** 2`).

Tokens usually opt for a value of 18, imitating the relationship between
Ether and Wei. This is the default value returned by this function, unless
it's overridden.

NOTE: This information is only used for _display_ purposes: it in
no way affects any of the arithmetic of the contract, including
{IERC20-balanceOf} and {IERC20-transfer}._

## TestToken

### constructor

```solidity
constructor(address recipient) public
```

## BaseGuard

### supportsInterface

```solidity
function supportsInterface(bytes4 interfaceId) external pure returns (bool)
```

_Returns true if this contract implements the interface defined by
`interfaceId`. See the corresponding
https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
to learn more about how these ids are created.

This function call must use less than 30 000 gas._

### checkTransaction

```solidity
function checkTransaction(address to, uint256 value, bytes data, enum Enum.Operation operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address payable refundReceiver, bytes signatures, address msgSender) external virtual
```

This interface is used to maintain compatibilty with Safe Wallet transaction guards.

_Module transactions only use the first four parameters: to, value, data, and operation.
Module.sol hardcodes the remaining parameters as 0 since they are not used for module transactions._

### checkAfterExecution

```solidity
function checkAfterExecution(bytes32 txHash, bool success) external virtual
```

## SafeGuard

A Telcoin Laboratories Contract
Designed to protect against non-compliant votes

### transactionHashes

```solidity
mapping(bytes32 => bool) transactionHashes
```

### nonces

```solidity
uint256[] nonces
```

### constructor

```solidity
constructor() public
```

### vetoTransaction

```solidity
function vetoTransaction(bytes32 transactionHash, uint256 nonce) public
```

Allows the contract owner to veto a transaction by its hash

_restricted to onlyOwner_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| transactionHash | bytes32 | Hash of the transaction to be vetoed |
| nonce | uint256 | Nonce of the transaction |

### checkTransaction

```solidity
function checkTransaction(address to, uint256 value, bytes data, enum Enum.Operation operation, uint256, uint256, uint256, address, address payable, bytes, address) external view
```

_Checks if a transaction has been vetoed by its hash_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| to | address | Address of the recipient of the transaction |
| value | uint256 | Value of the transaction |
| data | bytes | Data of the transaction |
| operation | enum Enum.Operation | Operation of the transaction |
|  | uint256 |  |
|  | uint256 |  |
|  | uint256 |  |
|  | address |  |
|  | address payable |  |
|  | bytes |  |
|  | address |  |

### checkAfterExecution

```solidity
function checkAfterExecution(bytes32, bool) external view
```

### fallback

```solidity
fallback() external
```

## Enum

### Operation

```solidity
enum Operation {
  Call,
  DelegateCall
}
```

## IBalanceHolder

### withdraw

```solidity
function withdraw() external
```

### balanceOf

```solidity
function balanceOf(address) external view returns (uint256)
```

## IGuard

### checkTransaction

```solidity
function checkTransaction(address to, uint256 value, bytes data, enum Enum.Operation operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address payable refundReceiver, bytes signatures, address msgSender) external
```

### checkAfterExecution

```solidity
function checkAfterExecution(bytes32 txHash, bool success) external
```

## IReality

### getTransactionHash

```solidity
function getTransactionHash(address to, uint256 value, bytes data, enum Enum.Operation operation, uint256 nonce) external view returns (bytes32)
```

Returns the transaction hash for a given transaction

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| to | address | The address the transaction is being sent to |
| value | uint256 | The amount of Ether being sent |
| data | bytes | The data being sent with the transaction |
| operation | enum Enum.Operation | The type of operation being performed |
| nonce | uint256 | The nonce of the transaction |

### notifyOfArbitrationRequest

```solidity
function notifyOfArbitrationRequest(bytes32 question_id, address requester, uint256 max_previous) external
```

Notify the contract that the arbitrator has been paid for a question, freezing it pending their decision.

_The arbitrator contract is trusted to only call this if they've been paid, and tell us who paid them._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| question_id | bytes32 | The ID of the question |
| requester | address | The account that requested arbitration |
| max_previous | uint256 | If specified, reverts if a bond higher than this was submitted after you sent your transaction. |

### submitAnswerByArbitrator

```solidity
function submitAnswerByArbitrator(bytes32 question_id, bytes32 answer, address answerer) external
```

Submit the answer for a question, for use by the arbitrator.

_Doesn't require (or allow) a bond.
If the current final answer is correct, the account should be whoever submitted it.
If the current final answer is wrong, the account should be whoever paid for arbitration.
However, the answerer stipulations are not enforced by the contract._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| question_id | bytes32 | The ID of the question |
| answer | bytes32 | The answer, encoded into bytes32 |
| answerer | address | The account credited with this answer for the purpose of bond claims |

### getBestAnswer

```solidity
function getBestAnswer(bytes32 question_id) external view returns (bytes32)
```

Returns the best answer for a question

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| question_id | bytes32 | The ID of the question |

## IRealityETH

### LogAnswerReveal

```solidity
event LogAnswerReveal(bytes32 question_id, address user, bytes32 answer_hash, bytes32 answer, uint256 nonce, uint256 bond)
```

### LogCancelArbitration

```solidity
event LogCancelArbitration(bytes32 question_id)
```

### LogClaim

```solidity
event LogClaim(bytes32 question_id, address user, uint256 amount)
```

### LogFinalize

```solidity
event LogFinalize(bytes32 question_id, bytes32 answer)
```

### LogFundAnswerBounty

```solidity
event LogFundAnswerBounty(bytes32 question_id, uint256 bounty_added, uint256 bounty, address user)
```

### LogMinimumBond

```solidity
event LogMinimumBond(bytes32 question_id, uint256 min_bond)
```

### LogNewAnswer

```solidity
event LogNewAnswer(bytes32 answer, bytes32 question_id, bytes32 history_hash, address user, uint256 bond, uint256 ts, bool is_commitment)
```

### LogNewQuestion

```solidity
event LogNewQuestion(bytes32 question_id, address user, uint256 template_id, string question, bytes32 content_hash, address arbitrator, uint32 timeout, uint32 opening_ts, uint256 nonce, uint256 created)
```

### LogNewTemplate

```solidity
event LogNewTemplate(uint256 template_id, address user, string question_text)
```

### LogNotifyOfArbitrationRequest

```solidity
event LogNotifyOfArbitrationRequest(bytes32 question_id, address user)
```

### LogReopenQuestion

```solidity
event LogReopenQuestion(bytes32 question_id, bytes32 reopened_question_id)
```

### LogSetQuestionFee

```solidity
event LogSetQuestionFee(address arbitrator, uint256 amount)
```

### assignWinnerAndSubmitAnswerByArbitrator

```solidity
function assignWinnerAndSubmitAnswerByArbitrator(bytes32 question_id, bytes32 answer, address payee_if_wrong, bytes32 last_history_hash, bytes32 last_answer_or_commitment_id, address last_answerer) external
```

### cancelArbitration

```solidity
function cancelArbitration(bytes32 question_id) external
```

### claimMultipleAndWithdrawBalance

```solidity
function claimMultipleAndWithdrawBalance(bytes32[] question_ids, uint256[] lengths, bytes32[] hist_hashes, address[] addrs, uint256[] bonds, bytes32[] answers) external
```

### claimWinnings

```solidity
function claimWinnings(bytes32 question_id, bytes32[] history_hashes, address[] addrs, uint256[] bonds, bytes32[] answers) external
```

### createTemplate

```solidity
function createTemplate(string content) external returns (uint256)
```

### notifyOfArbitrationRequest

```solidity
function notifyOfArbitrationRequest(bytes32 question_id, address requester, uint256 max_previous) external
```

### setQuestionFee

```solidity
function setQuestionFee(uint256 fee) external
```

### submitAnswerByArbitrator

```solidity
function submitAnswerByArbitrator(bytes32 question_id, bytes32 answer, address answerer) external
```

### submitAnswerReveal

```solidity
function submitAnswerReveal(bytes32 question_id, bytes32 answer, uint256 nonce, uint256 bond) external
```

### askQuestion

```solidity
function askQuestion(uint256 template_id, string question, address arbitrator, uint32 timeout, uint32 opening_ts, uint256 nonce) external payable returns (bytes32)
```

### askQuestionWithMinBond

```solidity
function askQuestionWithMinBond(uint256 template_id, string question, address arbitrator, uint32 timeout, uint32 opening_ts, uint256 nonce, uint256 min_bond) external payable returns (bytes32)
```

### createTemplateAndAskQuestion

```solidity
function createTemplateAndAskQuestion(string content, string question, address arbitrator, uint32 timeout, uint32 opening_ts, uint256 nonce) external payable returns (bytes32)
```

### fundAnswerBounty

```solidity
function fundAnswerBounty(bytes32 question_id) external payable
```

### reopenQuestion

```solidity
function reopenQuestion(uint256 template_id, string question, address arbitrator, uint32 timeout, uint32 opening_ts, uint256 nonce, uint256 min_bond, bytes32 reopens_question_id) external payable returns (bytes32)
```

### submitAnswer

```solidity
function submitAnswer(bytes32 question_id, bytes32 answer, uint256 max_previous) external payable
```

### submitAnswerCommitment

```solidity
function submitAnswerCommitment(bytes32 question_id, bytes32 answer_hash, uint256 max_previous, address _answerer) external payable
```

### submitAnswerFor

```solidity
function submitAnswerFor(bytes32 question_id, bytes32 answer, uint256 max_previous, address answerer) external payable
```

### arbitrator_question_fees

```solidity
function arbitrator_question_fees(address) external view returns (uint256)
```

### commitments

```solidity
function commitments(bytes32) external view returns (uint32 reveal_ts, bool is_revealed, bytes32 revealed_answer)
```

### getArbitrator

```solidity
function getArbitrator(bytes32 question_id) external view returns (address)
```

### getBestAnswer

```solidity
function getBestAnswer(bytes32 question_id) external view returns (bytes32)
```

### getBond

```solidity
function getBond(bytes32 question_id) external view returns (uint256)
```

### getBounty

```solidity
function getBounty(bytes32 question_id) external view returns (uint256)
```

### getContentHash

```solidity
function getContentHash(bytes32 question_id) external view returns (bytes32)
```

### getFinalAnswer

```solidity
function getFinalAnswer(bytes32 question_id) external view returns (bytes32)
```

### getFinalAnswerIfMatches

```solidity
function getFinalAnswerIfMatches(bytes32 question_id, bytes32 content_hash, address arbitrator, uint32 min_timeout, uint256 min_bond) external view returns (bytes32)
```

### getFinalizeTS

```solidity
function getFinalizeTS(bytes32 question_id) external view returns (uint32)
```

### getHistoryHash

```solidity
function getHistoryHash(bytes32 question_id) external view returns (bytes32)
```

### getMinBond

```solidity
function getMinBond(bytes32 question_id) external view returns (uint256)
```

### getOpeningTS

```solidity
function getOpeningTS(bytes32 question_id) external view returns (uint32)
```

### getTimeout

```solidity
function getTimeout(bytes32 question_id) external view returns (uint32)
```

### isFinalized

```solidity
function isFinalized(bytes32 question_id) external view returns (bool)
```

### isPendingArbitration

```solidity
function isPendingArbitration(bytes32 question_id) external view returns (bool)
```

### isSettledTooSoon

```solidity
function isSettledTooSoon(bytes32 question_id) external view returns (bool)
```

### question_claims

```solidity
function question_claims(bytes32) external view returns (address payee, uint256 last_bond, uint256 queued_funds)
```

### questions

```solidity
function questions(bytes32) external view returns (bytes32 content_hash, address arbitrator, uint32 opening_ts, uint32 timeout, uint32 finalize_ts, bool is_pending_arbitration, uint256 bounty, bytes32 best_answer, bytes32 history_hash, uint256 bond, uint256 min_bond)
```

### reopened_questions

```solidity
function reopened_questions(bytes32) external view returns (bytes32)
```

### reopener_questions

```solidity
function reopener_questions(bytes32) external view returns (bool)
```

### resultFor

```solidity
function resultFor(bytes32 question_id) external view returns (bytes32)
```

### resultForOnceSettled

```solidity
function resultForOnceSettled(bytes32 question_id) external view returns (bytes32)
```

### template_hashes

```solidity
function template_hashes(uint256) external view returns (bytes32)
```

### templates

```solidity
function templates(uint256) external view returns (uint256)
```

## MockSafeGuard

### PreviouslyVetoed

```solidity
error PreviouslyVetoed(bytes32 hash)
```

### transactionHashes

```solidity
mapping(bytes32 => bool) transactionHashes
```

### nonces

```solidity
uint256[] nonces
```

### constructor

```solidity
constructor() public
```

### vetoTransaction

```solidity
function vetoTransaction(bytes32 transactionHash, uint256 nonce) public
```

Allows the contract owner to veto a transaction by its hash

_restricted to onlyOwner_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| transactionHash | bytes32 | Hash of the transaction to be vetoed |
| nonce | uint256 | Nonce of the transaction |

### checkTransaction

```solidity
function checkTransaction(address to, uint256 value, bytes data, enum Enum.Operation operation, uint256, uint256, uint256, address, address payable, bytes, address) external view
```

_Checks if a transaction has been vetoed by its hash_

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| to | address | Address of the recipient of the transaction |
| value | uint256 | Value of the transaction |
| data | bytes | Data of the transaction |
| operation | enum Enum.Operation | Operation of the transaction |
|  | uint256 |  |
|  | uint256 |  |
|  | uint256 |  |
|  | address |  |
|  | address payable |  |
|  | bytes |  |
|  | address |  |

### checkAfterExecution

```solidity
function checkAfterExecution(bytes32, bool) external view
```

## TestReality

### Question

```solidity
struct Question {
  bytes32 bestAnswer;
  address answerer;
}
```

### get

```solidity
function get(string byteMe) external pure returns (bytes32)
```

### getTransactionHash

```solidity
function getTransactionHash(address to, uint256 value, bytes data, enum Enum.Operation operation, uint256 nonce) external pure returns (bytes32)
```

Returns the transaction hash for a given transaction

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| to | address | The address the transaction is being sent to |
| value | uint256 | The amount of Ether being sent |
| data | bytes | The data being sent with the transaction |
| operation | enum Enum.Operation | The type of operation being performed |
| nonce | uint256 | The nonce of the transaction |

### notifyOfArbitrationRequest

```solidity
function notifyOfArbitrationRequest(bytes32 question_id, address requester, uint256 max_previous) external
```

Notify the contract that the arbitrator has been paid for a question, freezing it pending their decision.

_The arbitrator contract is trusted to only call this if they've been paid, and tell us who paid them._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| question_id | bytes32 | The ID of the question |
| requester | address | The account that requested arbitration |
| max_previous | uint256 | If specified, reverts if a bond higher than this was submitted after you sent your transaction. |

### submitAnswerByArbitrator

```solidity
function submitAnswerByArbitrator(bytes32 question_id, bytes32 answer, address answerer) external
```

Submit the answer for a question, for use by the arbitrator.

_Doesn't require (or allow) a bond.
If the current final answer is correct, the account should be whoever submitted it.
If the current final answer is wrong, the account should be whoever paid for arbitration.
However, the answerer stipulations are not enforced by the contract._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| question_id | bytes32 | The ID of the question |
| answer | bytes32 | The answer, encoded into bytes32 |
| answerer | address | The account credited with this answer for the purpose of bond claims |

### getBestAnswer

```solidity
function getBestAnswer(bytes32 question_id) external view returns (bytes32)
```

Returns the best answer for a question

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| question_id | bytes32 | The ID of the question |

## TestSafeWallet

### _data

```solidity
bytes _data
```

### execTransactionFromModule

```solidity
function execTransactionFromModule(address, uint256, bytes data, enum Enum.Operation) external returns (bool success)
```

