# telcoin-laboratories-contracts

[![NPM Package](https://img.shields.io/badge/npm-1.0.0-blue)](https://www.npmjs.com/package/telcoin-laboratories-contracts)
![hardhat](https://img.shields.io/badge/hardhat-2.20.1-blue)
![node](https://img.shields.io/badge/node-v20.11.1-brightgreen.svg)
![solidity](https://img.shields.io/badge/solidity-0.8.24-red)
![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-^5.0.1-brightgreen.svg)
![coverage](https://img.shields.io/badge/coverage->80%25-yellowgreen)
![comments](https://img.shields.io/badge/comments->80%25-yellowgreen)

**Telcoin Labs** is the blockchain research and development arm of Telcoin. Labs researches, develops, and documents Telcoin Association infrastructure, including Telcoin Network, an evm-compatible, proof-of-stake blockchain network secured by mobile network operators, TELx, a DeFi network, application layer systems, and the Telcoin Platform governance system.

## Installation

## Hardhat (npm)

```shell
> npm install telcoin-laboratories-contracts
```

## Running Tests

To get started, all you should need to install dependencies and run the unit tests are here.

```shell
npm install
npm test
```

Under the hood `npm test` is running `npx hardhat clean && npx hardhat coverage`

For a quicker unit test run:

```shell
npx hardhat test
```

## Notes

Currently all contracts are unaudited and likely to change. Final versions will be updated here.

`Test` contracts are dummy contracts created for testing and are outside the scope of the audit. `Mock` contracts are created to be tested in place of the real contract. This is done for testing ease. In some cases using a slightly altered version is significantly simpler to test. This means some contracts show as no line coverage. Code coverage metrics only apply to contracts that have been created by Telcoin.

### Version

`nvm` use will switch to node `v20.11.1`

```txt
                                     ttttttttttttttt,                           
                              *tttttttttttttttttttttttt,                        
                       *tttttttttttttttttttttttttttttttttt,                     
                ,tttttttttttttttttttttttttttttttttttttttttttt,                  
          .ttttttttttttttttttttttttttttttttttttttttttttttttttttt.               
        ttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt.            
       ttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt.         
      ttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt       
     .ttttttttttttttttttttttttttttttttt    ttttttttttttttttttttttttttttttttt.   
     tttttttttttttttttttttttttttttttt     *ttttttttttttttttttttttttttttttttttt. 
     ttttttttttttttttttttttttttttt.       ttttttttttttttttttttttttttttttttttttt,
    *ttttttttttttttttttttttttt,          ************ttttttttttttttttttttttttttt
    tttttttttttttttttttttttt                        tttttttttttttttttttttttttttt
   *ttttttttttttttttttttttt*                        ttttttttttttttttttttttttttt,
   ttttttttttttttttttttttttttttt        *tttttttttttttttttttttttttttttttttttttt 
  ,tttttttttttttttttttttttttttt,       ,tttttttttttttttttttttttttttttttttttttt* 
  ttttttttttttttttttttttttttttt        ttttttttttttttttttttttttttttttttttttttt  
  tttttttttttttttttttttttttttt.       ,ttttttttttttttttttttttttttttttttttttttt  
 ttttttttttttttttttttttttttttt        ttttttttttttttttttttttttttttttttttttttt   
 ttttttttttttttttttttttttttttt        ttttttttttttttttttttttttttttttttttttttt   
 ttttttttttttttttttttttttttttt         *********tttttttttttttttttttttttttttt.   
 ttttttttttttttttttttttttttttt*                 tttttttttttttttttttttttttttt    
  *ttttttttttttttttttttttttttttt               tttttttttttttttttttttttttttt*    
    .tttttttttttttttttttttttttttttttttttttttttt*ttttttttttttttttttttttttttt     
       .ttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt     
          .ttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt      
             .tttttttttttttttttttttttttttttttttttttttttttttttttttttttttt,       
                .ttttttttttttttttttttttttttttttttttttttttttttttttttttt          
                   ,ttttttttttttttttttttttttttttttttttttttttttt*                
                      ,ttttttttttttttttttttttttttttttttt*                       
                         ,tttttttttttttttttttttttt.                             
                            ,*ttttttttttttt.                                    
```
