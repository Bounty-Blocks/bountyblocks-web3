# Our team's internal readme

## Deployment

Compile: ```npx hardhat compile```

Clean artifacts: ```npx hardhat clean```

### Deployment process

For testing, start a local hardhat chain: ```npx hardhat node```

Use hardhat ignition to deploy:
```npx hardhat ignition deploy ignition/modules/Counter.ts --network localhost```
(Should also work with sepolia and other networks)

## Configuration

The configuration pulls from the .env file at the root level of this project

## Testing

Run all tests: ```npx hardhat test```
Run a specific test: ```npx hardhat test test/[test file]```

## Reference

OpenZeppelin: <https://docs.openzeppelin.com/contracts/5.x/>
