// Copyright (c) Aptos
// SPDX-License-Identifier: Apache-2.0

import {
  Heading, Spinner, Text, useColorMode, VStack, Wrap,
} from '@chakra-ui/react';
import React from 'react';
import { useAccountCoinBalance } from 'core/queries/account';
import numeral from 'numeral';
import { secondaryAddressFontColor } from 'core/colors';
import { useActiveAccount } from 'core/hooks/useAccounts';

function WalletAccountBalance() {
  const { colorMode } = useColorMode();
  const { activeAccountAddress } = useActiveAccount();
  const {
    data: coinBalance,
    isLoading,
  } = useAccountCoinBalance(activeAccountAddress, {
    refetchInterval: 5000,
  });
  const coinBalanceString = numeral(coinBalance).format('0,0');
  return (
    <VStack px={4} alignItems="left">
      <Text fontSize="sm" color={secondaryAddressFontColor[colorMode]}>Account balance</Text>
      <Wrap alignItems="baseline">
        <span>
          {
            isLoading
              ? <Spinner size="md" thickness="3px" />
              : <Heading as="span" wordBreak="break-word" maxW="100%">{`${coinBalanceString}`}</Heading>
          }
          <Text pl={2} pb="2px" as="span" fontSize="xl" fontWeight={600}>
            APT
          </Text>
        </span>
      </Wrap>
    </VStack>
  );
}

export default WalletAccountBalance;
